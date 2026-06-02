import {
  createPublicClient,
  createWalletClient,
  http,
  formatEther,
  type Address,
  type Hash,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { vaultAbi, adapterAbi, vaultWriteAbi, adapterWriteAbi } from "./abi";
import type { IntentFired, MonitorConfig } from "./monitor";
import {
  resizeShortToTarget,
  getPosition,
  type HyperliquidConfig,
} from "./hyperliquid";

/* ///////////////////////////////////////////////////////////////
                          TYPES
/////////////////////////////////////////////////////////////// */

export interface ExecutorConfig extends MonitorConfig {
  privateKey: Hex;
  /** If set, enables real Hyperliquid trading before on-chain sync. */
  hyperliquid?: HyperliquidConfig;
}

export interface ExecutionResult {
  intent: IntentFired;
  txHash: Hash;
  success: boolean;
  error?: string;
}

/* ///////////////////////////////////////////////////////////////
                      POSITION TRACKING
/////////////////////////////////////////////////////////////// */

/**
 * Find the active position ID by querying PositionOpened events.
 * Returns the most recent positionId, or null if no position exists.
 */
async function findActivePositionId(
  config: ExecutorConfig
): Promise<Hex | null> {
  const client = createPublicClient({
    chain: sepolia,
    transport: http(config.rpcUrl),
  });

  const currentBlock = await client.getBlockNumber();

  // Search recent blocks for PositionOpened events (last ~50k blocks ≈ 1 week).
  const fromBlock = currentBlock > 50_000n ? currentBlock - 50_000n : 0n;

  const logs = await client.getLogs({
    address: config.adapterAddress,
    event: {
      type: "event",
      name: "PositionOpened",
      inputs: [
        { type: "bytes32", name: "posId", indexed: true },
        { type: "uint256", name: "notional", indexed: false },
      ],
    },
    fromBlock,
    toBlock: "latest",
  });

  if (logs.length === 0) return null;

  // Return the most recent position ID.
  return logs[logs.length - 1].args.posId as Hex;
}

/* ///////////////////////////////////////////////////////////////
                     EXECUTE RESIZE PERP
/////////////////////////////////////////////////////////////// */

async function executeResizePerp(
  config: ExecutorConfig,
  intent: IntentFired
): Promise<ExecutionResult> {
  const account = privateKeyToAccount(config.privateKey);
  const client = createWalletClient({
    account,
    chain: sepolia,
    transport: http(config.rpcUrl),
  });
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(config.rpcUrl),
  });

  // Target notional = vault's totalDepositedAssets (to match TVL perfectly).
  const targetNotional = await publicClient.readContract({
    address: config.vaultAddress,
    abi: vaultAbi,
    functionName: "totalDepositedAssets",
  });

  const currentNotional = await publicClient.readContract({
    address: config.adapterAddress,
    abi: adapterAbi,
    functionName: "totalHedgedNotional",
  });

  console.log(
    `[executor] RESIZE_SHORT_PERP: current=${formatEther(currentNotional)} target=${formatEther(targetNotional)}`
  );

  // ── Step 1: Execute REAL trade on Hyperliquid (if configured) ──
  if (config.hyperliquid) {
    const targetEth = Number(formatEther(targetNotional));
    console.log(`[executor] Hyperliquid: resizing real short to ${targetEth} ETH`);

    const hlResult = await resizeShortToTarget(config.hyperliquid, targetEth);

    if (!hlResult.success) {
      console.error(`[executor] Hyperliquid trade failed: ${hlResult.error}`);
      // Still continue with on-chain sync — the mock adapter tracks the target,
      // not the actual fill. This keeps the vault's coverage ratio correct.
    } else {
      console.log(
        `[executor] Hyperliquid: filled ${hlResult.filledSize} ETH @ $${hlResult.avgPrice}`
      );
    }

    // Log current HL position for observability
    const hlPos = await getPosition(config.hyperliquid);
    if (hlPos) {
      console.log(
        `[executor] Hyperliquid position: ${hlPos.sizeEth} ETH @ $${hlPos.entryPx} (PnL: $${hlPos.unrealisedPnl.toFixed(2)})`
      );
    }
  }

  // ── Step 2: Sync MockPerpAdapter on-chain ──

  let txHash: Hash;

  if (currentNotional === 0n) {
    // No position exists — open a new one.
    console.log(
      `[executor] Opening new position: ${formatEther(targetNotional)} ETH`
    );
    txHash = await client.writeContract({
      address: config.adapterAddress,
      abi: adapterWriteAbi,
      functionName: "openPosition",
      args: [targetNotional],
    });
  } else {
    // Position exists — resize it.
    const positionId = await findActivePositionId(config);
    if (!positionId) {
      return {
        intent,
        txHash: "0x0" as Hash,
        success: false,
        error: "No active position found in event logs",
      };
    }

    console.log(
      `[executor] Resizing position ${positionId} → ${formatEther(targetNotional)} ETH`
    );
    txHash = await client.writeContract({
      address: config.adapterAddress,
      abi: adapterWriteAbi,
      functionName: "resizePosition",
      args: [positionId as Hex, targetNotional],
    });
  }

  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });

  console.log(
    `[executor] TX ${txHash} — status: ${receipt.status}, gas: ${receipt.gasUsed}`
  );

  return {
    intent,
    txHash,
    success: receipt.status === "success",
  };
}

/* ///////////////////////////////////////////////////////////////
                    EXECUTE SETTLE BATCH
/////////////////////////////////////////////////////////////// */

async function executeSettleBatch(
  config: ExecutorConfig,
  intent: IntentFired
): Promise<ExecutionResult> {
  const account = privateKeyToAccount(config.privateKey);
  const client = createWalletClient({
    account,
    chain: sepolia,
    transport: http(config.rpcUrl),
  });
  const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(config.rpcUrl),
  });

  // Step 1: Read current batch ID and check if it needs closing.
  const batchId = await publicClient.readContract({
    address: config.vaultAddress,
    abi: vaultAbi,
    functionName: "currentBatchId",
  });

  const batch = await publicClient.readContract({
    address: config.vaultAddress,
    abi: vaultAbi,
    functionName: "getBatch",
    args: [batchId],
  });

  console.log(
    `[executor] SETTLE_BATCH: batchId=${batchId} isClosed=${batch.isClosed} isSettled=${batch.isSettled} assetsLocked=${batch.totalAssetsLocked}`
  );

  // Step 2: Close the batch if still open.
  if (!batch.isClosed) {
    console.log(`[executor] Closing batch ${batchId}...`);
    const closeTx = await client.writeContract({
      address: config.vaultAddress,
      abi: vaultWriteAbi,
      functionName: "closeBatch",
    });
    const closeReceipt = await publicClient.waitForTransactionReceipt({
      hash: closeTx,
    });
    console.log(
      `[executor] closeBatch TX ${closeTx} — status: ${closeReceipt.status}`
    );

    if (closeReceipt.status !== "success") {
      return {
        intent,
        txHash: closeTx,
        success: false,
        error: "closeBatch() reverted",
      };
    }
  }

  // Step 3: Approve wstETH to vault (for settleBatch pull pattern).
  // In the POC, assetsReturned = totalAssetsLocked (no real bridge slippage).
  const assetsToReturn = batch.totalAssetsLocked;

  if (assetsToReturn === 0n) {
    return {
      intent,
      txHash: "0x0" as Hash,
      success: false,
      error: "Batch has 0 assets locked — nothing to settle",
    };
  }

  // Read the wstETH address from vault.
  const wstETH = await publicClient.readContract({
    address: config.vaultAddress,
    abi: vaultAbi,
    functionName: "asset",
  });

  // Check keeper's wstETH balance.
  const keeperBalance = await publicClient.readContract({
    address: wstETH,
    abi: [
      {
        inputs: [{ name: "account", type: "address" }],
        name: "balanceOf",
        outputs: [{ name: "", type: "uint256" }],
        stateMutability: "view",
        type: "function",
      },
    ] as const,
    functionName: "balanceOf",
    args: [account.address],
  });

  if (keeperBalance < assetsToReturn) {
    console.log(
      `[executor] Insufficient wstETH: have=${formatEther(keeperBalance)} need=${formatEther(assetsToReturn)}`
    );
    return {
      intent,
      txHash: "0x0" as Hash,
      success: false,
      error: `Insufficient wstETH for settlement: have ${formatEther(keeperBalance)}, need ${formatEther(assetsToReturn)}`,
    };
  }

  // Approve vault to pull wstETH.
  console.log(
    `[executor] Approving ${formatEther(assetsToReturn)} wstETH to vault...`
  );
  const approveTx = await client.writeContract({
    address: wstETH,
    abi: [
      {
        inputs: [
          { name: "spender", type: "address" },
          { name: "amount", type: "uint256" },
        ],
        name: "approve",
        outputs: [{ name: "", type: "bool" }],
        stateMutability: "nonpayable",
        type: "function",
      },
    ] as const,
    functionName: "approve",
    args: [config.vaultAddress, assetsToReturn],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveTx });

  // Step 4: Settle the batch.
  console.log(
    `[executor] Settling batch ${batchId} with ${formatEther(assetsToReturn)} wstETH...`
  );
  const settleTx = await client.writeContract({
    address: config.vaultAddress,
    abi: vaultWriteAbi,
    functionName: "settleBatch",
    args: [batchId as Hex, assetsToReturn],
  });
  const settleReceipt = await publicClient.waitForTransactionReceipt({
    hash: settleTx,
  });

  console.log(
    `[executor] settleBatch TX ${settleTx} — status: ${settleReceipt.status}`
  );

  return {
    intent,
    txHash: settleTx,
    success: settleReceipt.status === "success",
  };
}

/* ///////////////////////////////////////////////////////////////
                       PUBLIC API
/////////////////////////////////////////////////////////////// */

export async function executeIntent(
  config: ExecutorConfig,
  intent: IntentFired
): Promise<ExecutionResult> {
  try {
    switch (intent.kind) {
      case "RESIZE_SHORT_PERP":
        return await executeResizePerp(config, intent);
      case "SETTLE_REDEMPTION_BATCH":
        return await executeSettleBatch(config, intent);
      default:
        return {
          intent,
          txHash: "0x0" as Hash,
          success: false,
          error: `Unknown intent kind: ${intent.kind}`,
        };
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[executor] Failed to execute ${intent.kind}:`, message);
    return {
      intent,
      txHash: "0x0" as Hash,
      success: false,
      error: message,
    };
  }
}

export async function executeAll(
  config: ExecutorConfig,
  intents: IntentFired[]
): Promise<ExecutionResult[]> {
  const results: ExecutionResult[] = [];

  // Execute sequentially to avoid nonce conflicts.
  for (const intent of intents) {
    console.log(`[executor] Executing intent: ${intent.kind}`);
    const result = await executeIntent(config, intent);
    results.push(result);

    if (!result.success) {
      console.error(
        `[executor] Intent ${intent.kind} failed: ${result.error}`
      );
      // Continue with next intent — don't abort the cycle.
    }
  }

  return results;
}
