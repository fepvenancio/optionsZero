/**
 * OptionZero — Gelato Web3 Function
 *
 * Runs on a cron schedule. Reads Vault state from Sepolia, fires ERC-7683
 * CrossChainOrder intents into intents.testnet when either trigger trips:
 *
 *   Trigger 1 — Size Imbalance:
 *     |TVL - perpNotional| / TVL > imbalanceThresholdBps / 10_000
 *     → RESIZE_SHORT_PERP intent
 *
 *   Trigger 2 — Pending Batch:
 *     totalPendingRedemption > 0 AND batch open > batchWindowBlocks
 *     → SETTLE_REDEMPTION_BATCH intent
 *
 * NEAR submission uses near-api-js v3 account.functionCall() which handles
 * ed25519 signing, borsh serialization, and broadcast_tx_async internally.
 * Gelato's only job is dropping the payload into intents.testnet — the
 * decentralized solver network handles everything after.
 */

import {
  Web3Function,
  Web3FunctionContext,
} from "@gelatonetwork/web3-functions-sdk";
import { ethers } from "ethers";
import * as nearAPI from "near-api-js";

/* ─────────────────────────────────────────────────────────────────────────────
                                    TYPES
───────────────────────────────────────────────────────────────────────────── */

type IntentKind = "RESIZE_SHORT_PERP" | "SETTLE_REDEMPTION_BATCH";

interface CrossChainOrder {
  orderType:      string;
  originChainId:  number;
  fillDeadline:   number;
  nonce:          number;
  intent: {
    action:              IntentKind;
    targetPerpSizeUsd:   string;
    sizeDeltaWstETH:     string;
    side:                "SHORT";
    venue:               "Hyperliquid";
    settlementBatchId?:  string;
    assetsToReturnWei?:  string;
  };
}

/* ─────────────────────────────────────────────────────────────────────────────
                                  CONSTANTS
───────────────────────────────────────────────────────────────────────────── */

/// Sepolia chain ID
const ORIGIN_CHAIN_ID = 11155111;

/// intents.testnet — canonical NEAR ERC-7683 solver bus
const INTENTS_CONTRACT = "intents.testnet";

/// Method on intents.testnet that accepts CrossChainOrder payloads
const INTENTS_METHOD = "execute_intents";

/// 30 TGas
const NEAR_GAS = BigInt("30000000000000");

/// 0.1 NEAR attached for storage deposit
const NEAR_DEPOSIT = BigInt("100000000000000000000000");

/// Fallback ETH/USD price — replace with Chainlink in production
const ETH_USD_PRICE = 3_000;

/// Gelato storage key for deduplication nonce
const NONCE_KEY = "intent_nonce";

/* ─────────────────────────────────────────────────────────────────────────────
                               MINIMAL ABIs
───────────────────────────────────────────────────────────────────────────── */

const VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function totalPendingRedemption() view returns (uint128)",
  "function currentBatchId() view returns (bytes32)",
];

const ADAPTER_ABI = [
  "function totalHedgedNotional() view returns (uint256)",
];

/* ─────────────────────────────────────────────────────────────────────────────
                               MAIN HANDLER
───────────────────────────────────────────────────────────────────────────── */

Web3Function.onRun(async (context: Web3FunctionContext) => {
  const { multiChainProvider, userArgs, secrets, storage } = context;

  // ── Config ──────────────────────────────────────────────────────────────
  const vaultAddress   = userArgs.vaultAddress   as string;
  const adapterAddress = userArgs.adapterAddress as string;
  const thresholdBps   = BigInt((userArgs.imbalanceThresholdBps as number) ?? 100);
  const batchWindow    = BigInt((userArgs.batchWindowBlocks     as number) ?? 300);

  const nearRpcUrl     = (await secrets.get("NEAR_RPC_URL"))     ?? "https://rpc.testnet.near.org";
  const nearAccountId  = (await secrets.get("NEAR_ACCOUNT_ID"))  ?? "";
  const nearPrivateKey = (await secrets.get("NEAR_PRIVATE_KEY")) ?? "";

  if (!nearAccountId || !nearPrivateKey) {
    return { canExec: false, message: "NEAR_ACCOUNT_ID or NEAR_PRIVATE_KEY secret not set" };
  }

  // ── Provider + contracts ────────────────────────────────────────────────
  const provider = multiChainProvider.default();
  const vault    = new ethers.Contract(vaultAddress,   VAULT_ABI,   provider);
  const adapter  = new ethers.Contract(adapterAddress, ADAPTER_ABI, provider);

  // ── Read on-chain state in parallel ─────────────────────────────────────
  const [
    totalAssetsRaw,
    totalHedgedRaw,
    pendingRedemptionRaw,
    currentBatchId,
    currentBlock,
  ] = await Promise.all([
    vault.totalAssets()            as Promise<ethers.BigNumber>,
    adapter.totalHedgedNotional()  as Promise<ethers.BigNumber>,
    vault.totalPendingRedemption() as Promise<ethers.BigNumber>,
    vault.currentBatchId()         as Promise<string>,
    provider.getBlockNumber(),
  ]);

  const totalAssets     = BigInt(totalAssetsRaw.toString());
  const totalHedged     = BigInt(totalHedgedRaw.toString());
  const pendingShares   = BigInt(pendingRedemptionRaw.toString());
  const currentBlockBig = BigInt(currentBlock);

  // ── Nonce (monotonic per-cycle deduplication) ────────────────────────────
  let nonce = parseInt((await storage.get(NONCE_KEY)) ?? "0");
  const now = Math.floor(Date.now() / 1000);
  const fired: string[] = [];

  // ── Trigger 1: Size Imbalance ─────────────────────────────────────────────
  if (totalAssets > 0n) {
    const absDelta     = totalAssets > totalHedged
      ? totalAssets - totalHedged
      : totalHedged - totalAssets;
    const imbalanceBps = (absDelta * 10_000n) / totalAssets;

    if (imbalanceBps > thresholdBps) {
      const sizeDeltaWad = totalAssets > totalHedged
        ? totalAssets - totalHedged
        : -(totalHedged - totalAssets);

      const sizeDeltaEth = Number(sizeDeltaWad) / 1e18;
      const targetUsd    = (Number(totalAssets) / 1e18) * ETH_USD_PRICE;

      const order: CrossChainOrder = {
        orderType:     "OptionZeroPerpResizeIntent",
        originChainId: ORIGIN_CHAIN_ID,
        fillDeadline:  now + 300,
        nonce,
        intent: {
          action:            "RESIZE_SHORT_PERP",
          targetPerpSizeUsd: targetUsd.toFixed(2),
          sizeDeltaWstETH:   sizeDeltaEth.toFixed(8),
          side:              "SHORT",
          venue:             "Hyperliquid",
        },
      };

      const txHash = await submitToNear({ nearRpcUrl, nearAccountId, nearPrivateKey, order });
      fired.push(
        `RESIZE_SHORT_PERP imbalance=${Number(imbalanceBps) / 100}% delta=${sizeDeltaEth.toFixed(4)} wstETH nearTx=${txHash}`
      );
      nonce++;
    }
  }

  // ── Trigger 2: Pending Batch ──────────────────────────────────────────────
  if (pendingShares > 0n) {
    const storageKey   = `batch_first_seen_${currentBatchId}`;
    const storedBlock  = await storage.get(storageKey);
    let firstSeenBlock = storedBlock ? BigInt(storedBlock) : 0n;

    if (firstSeenBlock === 0n) {
      firstSeenBlock = currentBlockBig;
      await storage.set(storageKey, currentBlockBig.toString());
    }

    const blocksElapsed = currentBlockBig - firstSeenBlock;

    if (blocksElapsed >= batchWindow) {
      const assetsToReturn = pendingShares;
      const postSettleEth  = Math.max(
        0,
        (Number(totalAssets) / 1e18) - (Number(assetsToReturn) / 1e18)
      );

      const order: CrossChainOrder = {
        orderType:     "OptionZeroSettlementIntent",
        originChainId: ORIGIN_CHAIN_ID,
        fillDeadline:  now + 300,
        nonce,
        intent: {
          action:             "SETTLE_REDEMPTION_BATCH",
          targetPerpSizeUsd:  (postSettleEth * ETH_USD_PRICE).toFixed(2),
          sizeDeltaWstETH:    (-(Number(assetsToReturn) / 1e18)).toFixed(8),
          side:               "SHORT",
          venue:              "Hyperliquid",
          settlementBatchId:  currentBatchId,
          assetsToReturnWei:  assetsToReturn.toString(),
        },
      };

      const txHash = await submitToNear({ nearRpcUrl, nearAccountId, nearPrivateKey, order });
      fired.push(
        `SETTLE_REDEMPTION_BATCH batch=${currentBatchId.slice(0, 10)}… blocks=${blocksElapsed} nearTx=${txHash}`
      );
      await storage.delete(storageKey);
      nonce++;
    }
  }

  // ── Persist nonce + respond ───────────────────────────────────────────────
  if (fired.length > 0) {
    await storage.set(NONCE_KEY, nonce.toString());
    return { canExec: false, message: `Intents submitted — ${fired.join(" | ")}` };
  }

  return {
    canExec: false,
    message: [
      `Balanced`,
      `assets=${fmt(totalAssets)} wstETH`,
      `notional=${fmt(totalHedged)} wstETH`,
      `pending=${pendingShares} shares`,
    ].join(" | "),
  };
});

/* ─────────────────────────────────────────────────────────────────────────────
                        NEAR TRANSACTION SUBMISSION
   Uses near-api-js v3 account.functionCall() which internally handles:
     • ed25519 signing with the provided key pair
     • borsh serialization of the SignedTransaction
     • broadcast_tx_async to the NEAR RPC
───────────────────────────────────────────────────────────────────────────── */

async function submitToNear(params: {
  nearRpcUrl:     string;
  nearAccountId:  string;
  nearPrivateKey: string;
  order:          CrossChainOrder;
}): Promise<string> {
  const { nearRpcUrl, nearAccountId, nearPrivateKey, order } = params;

  // Load the ed25519 key pair into an in-memory key store
  const keyStore = new nearAPI.keyStores.InMemoryKeyStore();
  const keyPair  = nearAPI.KeyPair.fromString(nearPrivateKey);
  await keyStore.setKey("testnet", nearAccountId, keyPair);

  // Connect to the NEAR testnet
  const near = await nearAPI.connect({
    networkId: "testnet",
    keyStore,
    nodeUrl:   nearRpcUrl,
  });

  const account = await near.account(nearAccountId);

  // Submit the ERC-7683 CrossChainOrder to intents.testnet
  // The solver network watches this contract and routes based on intent.action
  const result = await account.functionCall({
    contractId:      INTENTS_CONTRACT,
    methodName:      INTENTS_METHOD,
    args:            { intents: [order] },
    gas:             NEAR_GAS,
    attachedDeposit: NEAR_DEPOSIT,
  });

  // Return the NEAR transaction hash for logging
  return result.transaction.hash;
}

/* ─────────────────────────────────────────────────────────────────────────────
                                  HELPERS
───────────────────────────────────────────────────────────────────────────── */

function fmt(wei: bigint): string {
  return (Number(wei) / 1e18).toFixed(4);
}
