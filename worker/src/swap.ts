/**
 * 1inch Swap API integration for Arbitrum.
 *
 * Uses the 1inch Aggregation API (v6.0) for wstETH → USDC swaps.
 * MEV protection: Arbitrum's centralized sequencer uses FCFS ordering
 * (no public mempool), plus tight slippage tolerance.
 *
 * Flow:
 *   1. GET /quote    — price check (no tx)
 *   2. GET /approve  — get approve calldata (one-time)
 *   3. GET /swap     — get optimized swap calldata
 *   4. Sign + broadcast via keeper wallet
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  formatUnits,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";

/* ///////////////////////////////////////////////////////////////
                          CONSTANTS
/////////////////////////////////////////////////////////////// */

const ONEINCH_BASE_URL = "https://api.1inch.dev/swap/v6.0/42161"; // Arbitrum chain ID

/// wstETH on Arbitrum (Lido canonical)
export const WSTETH_ADDRESS: Address =
  "0x5979D7b546E38E414F7E9822514be443A4800529";

/// Native USDC on Arbitrum (Circle)
export const USDC_ADDRESS: Address =
  "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

/// Default slippage: 0.5%
const DEFAULT_SLIPPAGE = 0.5;

/* ///////////////////////////////////////////////////////////////
                            TYPES
/////////////////////////////////////////////////////////////// */

export interface SwapConfig {
  /** 1inch API key (Bearer token) */
  oneInchApiKey: string;
  /** Arbitrum RPC URL */
  rpcUrl: string;
  /** Keeper private key for signing txs */
  privateKey: Hex;
}

export interface QuoteResult {
  /** Input amount (human-readable wstETH) */
  srcAmount: string;
  /** Output amount (human-readable USDC) */
  dstAmount: string;
  /** Estimated gas */
  gas: number;
}

export interface SwapResult {
  success: boolean;
  txHash?: string;
  srcAmount?: string;
  dstAmount?: string;
  error?: string;
}

/* ///////////////////////////////////////////////////////////////
                        API HELPERS
/////////////////////////////////////////////////////////////// */

async function oneInchFetch(
  endpoint: string,
  apiKey: string,
  params: Record<string, string>
): Promise<Record<string, unknown>> {
  const url = new URL(`${ONEINCH_BASE_URL}${endpoint}`);
  for (const [k, v] of Object.entries(params)) {
    url.searchParams.set(k, v);
  }

  const res = await fetch(url.toString(), {
    headers: { Authorization: `Bearer ${apiKey}` },
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`1inch API error ${res.status}: ${text}`);
  }

  return (await res.json()) as Record<string, unknown>;
}

/* ///////////////////////////////////////////////////////////////
                          QUOTE
/////////////////////////////////////////////////////////////// */

/**
 * Get a price quote for wstETH → USDC on Arbitrum.
 * No transaction is created — purely informational.
 */
export async function getQuote(
  config: SwapConfig,
  amountWstEthWei: string
): Promise<QuoteResult> {
  const data = await oneInchFetch("/quote", config.oneInchApiKey, {
    src: WSTETH_ADDRESS,
    dst: USDC_ADDRESS,
    amount: amountWstEthWei,
  });

  return {
    srcAmount: formatUnits(BigInt(amountWstEthWei), 18),
    dstAmount: formatUnits(BigInt(data.dstAmount as string), 6),
    gas: Number(data.gas ?? 0),
  };
}

/* ///////////////////////////////////////////////////////////////
                      APPROVE (one-time)
/////////////////////////////////////////////////////////////// */

/**
 * Check if the keeper wallet has sufficient wstETH allowance for 1inch router.
 * If not, execute an approve transaction.
 */
export async function ensureApproval(
  config: SwapConfig,
  amountWei: string
): Promise<Hex | null> {
  const account = privateKeyToAccount(config.privateKey);

  // Check current allowance
  const allowanceData = await oneInchFetch(
    "/approve/allowance",
    config.oneInchApiKey,
    {
      tokenAddress: WSTETH_ADDRESS,
      walletAddress: account.address,
    }
  );

  const currentAllowance = BigInt(
    (allowanceData.allowance as string) ?? "0"
  );
  const needed = BigInt(amountWei);

  if (currentAllowance >= needed) {
    console.log("[1inch] Allowance sufficient, skipping approve");
    return null;
  }

  // Get approve tx data
  const approveTxData = await oneInchFetch(
    "/approve/transaction",
    config.oneInchApiKey,
    {
      tokenAddress: WSTETH_ADDRESS,
      amount: amountWei,
    }
  );

  // Send approve tx
  const walletClient = createWalletClient({
    account,
    chain: arbitrum,
    transport: http(config.rpcUrl),
  });

  const publicClient = createPublicClient({
    chain: arbitrum,
    transport: http(config.rpcUrl),
  });

  const txHash = await walletClient.sendTransaction({
    to: approveTxData.to as Address,
    data: approveTxData.data as Hex,
    value: BigInt((approveTxData.value as string) ?? "0"),
  });

  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`[1inch] Approved wstETH: ${txHash}`);

  return txHash;
}

/* ///////////////////////////////////////////////////////////////
                        SWAP EXECUTION
/////////////////////////////////////////////////////////////// */

/**
 * Execute a wstETH → USDC swap via 1inch on Arbitrum.
 *
 * @param config     Swap configuration (API key, RPC, private key)
 * @param amountWei  Amount of wstETH in wei to swap
 * @param slippage   Slippage tolerance in % (default: 0.5%)
 */
export async function swapWstEthToUsdc(
  config: SwapConfig,
  amountWei: string,
  slippage: number = DEFAULT_SLIPPAGE
): Promise<SwapResult> {
  const account = privateKeyToAccount(config.privateKey);

  try {
    // Step 1: Ensure approval
    await ensureApproval(config, amountWei);

    // Step 2: Get swap calldata from 1inch
    console.log(
      `[1inch] Getting swap calldata for ${formatUnits(BigInt(amountWei), 18)} wstETH → USDC...`
    );

    const swapData = await oneInchFetch("/swap", config.oneInchApiKey, {
      src: WSTETH_ADDRESS,
      dst: USDC_ADDRESS,
      amount: amountWei,
      from: account.address,
      slippage: slippage.toString(),
      disableEstimate: "false",
    });

    const tx = swapData.tx as Record<string, string>;
    const dstAmount = formatUnits(
      BigInt(swapData.dstAmount as string),
      6
    );

    console.log(`[1inch] Quoted: ${dstAmount} USDC, gas: ${tx.gas}`);

    // Step 3: Send the swap transaction
    const walletClient = createWalletClient({
      account,
      chain: arbitrum,
      transport: http(config.rpcUrl),
    });

    const publicClient = createPublicClient({
      chain: arbitrum,
      transport: http(config.rpcUrl),
    });

    const txHash = await walletClient.sendTransaction({
      to: tx.to as Address,
      data: tx.data as Hex,
      value: BigInt(tx.value ?? "0"),
      gas: BigInt(tx.gas),
    });

    const receipt = await publicClient.waitForTransactionReceipt({
      hash: txHash,
    });

    console.log(
      `[1inch] Swap complete: ${txHash} (block ${receipt.blockNumber})`
    );

    return {
      success: true,
      txHash,
      srcAmount: formatUnits(BigInt(amountWei), 18),
      dstAmount,
    };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[1inch] Swap failed: ${msg}`);
    return {
      success: false,
      error: msg,
    };
  }
}
