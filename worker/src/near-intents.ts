/**
 * NEAR Intents integration via the Defuse 1Click REST API.
 * Pure `fetch()` — no SDK deps, fully compatible with Cloudflare Workers.
 *
 * Flow:
 *   1. POST /v0/quote → get deposit address + estimated USDC output
 *   2. Send ETH to deposit address on Ethereum
 *   3. POST /v0/deposit/submit → speed up detection (optional)
 *   4. GET /v0/status → poll until SUCCESS or REFUNDED
 *   5. USDC arrives at recipient on Arbitrum
 *
 * Architecture note:
 *   wstETH is NOT on the 1Click token list. The vault unwraps wstETH → ETH
 *   (on Ethereum) before bridging. The 1Click solver handles ETH → USDC
 *   cross-chain swap and delivers native USDC to Arbitrum.
 */

import type { Hex } from "viem";

/* ///////////////////////////////////////////////////////////////
                          CONSTANTS
/////////////////////////////////////////////////////////////// */

const ONECLICK_BASE_URL = "https://1click.chaindefuser.com";

/// 1Click asset IDs (from /v0/tokens)
const ETH_ETHEREUM_ASSET_ID = "nep141:eth.omft.near";
const USDC_ARBITRUM_ASSET_ID =
  "nep141:arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near";

/* ///////////////////////////////////////////////////////////////
                            TYPES
/////////////////////////////////////////////////////////////// */

export interface NearIntentsConfig {
  /** Dry run mode — get quotes but don't generate deposit addresses. Default: true */
  dryRun: boolean;
  /** Recipient address on Arbitrum for USDC output */
  arbitrumRecipient: Hex;
  /** Refund address on Ethereum if swap fails */
  ethereumRefundAddress: Hex;
  /** Slippage tolerance in basis points. Default: 100 (1%) */
  slippageBps: number;
  /** JWT token for fee waiver (optional — 0.2% fee without it) */
  jwtToken?: string;
}

export interface SwapQuote {
  /** Deposit address to send ETH to on Ethereum */
  depositAddress: string;
  /** Estimated USDC output (human-readable, e.g. "1879.40") */
  estimatedOutputUsdc: string;
  /** Quote deadline ISO timestamp */
  deadline: string;
  /** Raw response for debugging */
  raw: unknown;
}

export type SwapStatusType =
  | "PENDING_DEPOSIT"
  | "KNOWN_DEPOSIT_TX"
  | "PROCESSING"
  | "SUCCESS"
  | "INCOMPLETE_DEPOSIT"
  | "REFUNDED"
  | "FAILED";

export interface SwapStatus {
  status: SwapStatusType;
  /** Output amount in smallest unit (if SUCCESS) */
  outputAmount?: string;
  /** Destination tx hash (if SUCCESS) */
  txHash?: string;
  /** Raw response */
  raw: unknown;
}

/* ///////////////////////////////////////////////////////////////
                      SUPPORTED TOKENS
/////////////////////////////////////////////////////////////// */

export interface OneClickToken {
  assetId: string;
  decimals: number;
  blockchain: string;
  symbol: string;
  price: number;
  contractAddress: string | null;
}

/**
 * Fetch all tokens supported by the 1Click API.
 * Useful for verifying asset IDs and checking prices.
 */
export async function fetchSupportedTokens(): Promise<OneClickToken[]> {
  const res = await fetch(`${ONECLICK_BASE_URL}/v0/tokens`);
  if (!res.ok) {
    throw new Error(`1Click /tokens failed: ${res.status} ${res.statusText}`);
  }
  return res.json() as Promise<OneClickToken[]>;
}

/**
 * Find a specific token by symbol and blockchain.
 */
export async function findToken(
  symbol: string,
  blockchain: string
): Promise<OneClickToken | null> {
  const tokens = await fetchSupportedTokens();
  return (
    tokens.find(
      (t) =>
        t.symbol === symbol &&
        t.blockchain === blockchain
    ) ?? null
  );
}

/* ///////////////////////////////////////////////////////////////
                      QUOTE + SWAP
/////////////////////////////////////////////////////////////// */

/**
 * Request a swap quote for ETH (Ethereum) → USDC (Arbitrum).
 *
 * @param config NEAR intents configuration
 * @param amountWei ETH amount in wei (string, e.g. "1000000000000000000" = 1 ETH)
 * @returns SwapQuote with deposit address (or dry quote without)
 */
export async function getSwapQuote(
  config: NearIntentsConfig,
  amountWei: string
): Promise<SwapQuote> {
  const deadline = new Date(Date.now() + 5 * 60 * 1000).toISOString();

  const body = {
    dry: config.dryRun,
    swapType: "EXACT_INPUT",
    slippageTolerance: config.slippageBps,
    originAsset: ETH_ETHEREUM_ASSET_ID,
    depositType: "ORIGIN_CHAIN",
    destinationAsset: USDC_ARBITRUM_ASSET_ID,
    amount: amountWei,
    recipient: config.arbitrumRecipient,
    recipientType: "DESTINATION_CHAIN",
    refundTo: config.ethereumRefundAddress,
    refundType: "ORIGIN_CHAIN",
    deadline,
  };

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (config.jwtToken) {
    headers["Authorization"] = `Bearer ${config.jwtToken}`;
  }

  console.log(
    `[near-intents] Requesting quote: ${amountWei} wei ETH → USDC (Arbitrum) dry=${config.dryRun}`
  );

  const res = await fetch(`${ONECLICK_BASE_URL}/v0/quote`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`1Click /quote failed: ${res.status} — ${errText}`);
  }

  const data = (await res.json()) as Record<string, unknown>;

  // Parse the estimated output
  const estimatedOutputRaw = String(data.estimatedOutput ?? data.outputAmount ?? "0");
  const estimatedOutputUsdc = (
    parseFloat(estimatedOutputRaw) / 1e6
  ).toFixed(2);

  console.log(
    `[near-intents] Quote received: ~$${estimatedOutputUsdc} USDC, deposit=${data.depositAddress ?? "DRY"}`
  );

  return {
    depositAddress: String(data.depositAddress ?? ""),
    estimatedOutputUsdc,
    deadline,
    raw: data,
  };
}

/* ///////////////////////////////////////////////////////////////
                   SUBMIT DEPOSIT TX
/////////////////////////////////////////////////////////////// */

/**
 * Notify 1Click that a deposit has been sent to speed up detection.
 *
 * @param depositAddress The deposit address from the quote
 * @param txHash The Ethereum transaction hash
 */
export async function submitDepositTx(
  depositAddress: string,
  txHash: string
): Promise<void> {
  console.log(
    `[near-intents] Submitting deposit tx: ${txHash} → ${depositAddress}`
  );

  const res = await fetch(`${ONECLICK_BASE_URL}/v0/deposit/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ depositAddress, txHash }),
  });

  if (!res.ok) {
    const errText = await res.text();
    console.warn(
      `[near-intents] Submit deposit warning: ${res.status} — ${errText}`
    );
  }
}

/* ///////////////////////////////////////////////////////////////
                    POLL SWAP STATUS
/////////////////////////////////////////////////////////////// */

/**
 * Check the status of a swap by deposit address.
 *
 * @param depositAddress The deposit address from the quote
 * @param depositMemo Optional memo from the quote (if provided)
 */
export async function getSwapStatus(
  depositAddress: string,
  depositMemo?: string
): Promise<SwapStatus> {
  let url = `${ONECLICK_BASE_URL}/v0/status?depositAddress=${depositAddress}`;
  if (depositMemo) {
    url += `&depositMemo=${depositMemo}`;
  }

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`1Click /status failed: ${res.status}`);
  }

  const data = (await res.json()) as Record<string, unknown>;

  return {
    status: String(data.status ?? "PENDING_DEPOSIT") as SwapStatusType,
    outputAmount: data.outputAmount ? String(data.outputAmount) : undefined,
    txHash: data.txHash ? String(data.txHash) : undefined,
    raw: data,
  };
}

/**
 * Poll swap status until terminal state (SUCCESS, REFUNDED, or FAILED).
 * Returns immediately if already terminal.
 *
 * @param depositAddress The deposit address from the quote
 * @param maxWaitMs Maximum time to wait (default: 15 minutes)
 * @param pollIntervalMs Polling interval (default: 10 seconds)
 */
export async function waitForSwapCompletion(
  depositAddress: string,
  maxWaitMs = 15 * 60 * 1000,
  pollIntervalMs = 10_000
): Promise<SwapStatus> {
  const terminalStatuses: SwapStatusType[] = [
    "SUCCESS",
    "REFUNDED",
    "FAILED",
  ];

  const startTime = Date.now();

  while (Date.now() - startTime < maxWaitMs) {
    const status = await getSwapStatus(depositAddress);

    console.log(`[near-intents] Swap status: ${status.status}`);

    if (terminalStatuses.includes(status.status)) {
      return status;
    }

    // Wait before next poll
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }

  throw new Error(
    `[near-intents] Swap timeout after ${maxWaitMs / 1000}s — last status not terminal`
  );
}
