/**
 * Hyperliquid integration — opens/resizes/closes short ETH-PERP positions
 * via the @nktkas/hyperliquid SDK. Compatible with Cloudflare Workers.
 *
 * Architecture:
 *   Worker detects TVL imbalance → calls Hyperliquid API to resize real short
 *   → syncs MockPerpAdapter on-chain (so Trancher coverage stays correct)
 */

import {
  HttpTransport,
  ExchangeClient,
  InfoClient,
} from "@nktkas/hyperliquid";
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";

/* ///////////////////////////////////////////////////////////////
                          CONSTANTS
/////////////////////////////////////////////////////////////// */

/// ETH-PERP asset index on Hyperliquid (perps universe)
/// BTC=0, ETH=1 — stable since launch, verified via /info meta
const ETH_ASSET_INDEX = 1;

/// Slippage tolerance for IOC market orders (in %)
const SLIPPAGE_PCT = 2;

/* ///////////////////////////////////////////////////////////////
                          TYPES
/////////////////////////////////////////////////////////////// */

export interface HyperliquidConfig {
  privateKey: Hex;
  isTestnet: boolean;
}

export interface HyperliquidPosition {
  /** Size in ETH (positive = long, negative = short) */
  sizeEth: number;
  /** Entry price in USD */
  entryPx: number;
  /** Unrealised PnL in USD */
  unrealisedPnl: number;
  /** Leverage */
  leverage: number;
}

export interface HyperliquidTradeResult {
  success: boolean;
  filledSize: number;
  avgPrice: number;
  error?: string;
}

/* ///////////////////////////////////////////////////////////////
                     CLIENT FACTORY
/////////////////////////////////////////////////////////////// */

function createClients(config: HyperliquidConfig) {
  const wallet = privateKeyToAccount(config.privateKey);
  const transport = new HttpTransport({ isTestnet: config.isTestnet });

  const info = new InfoClient({ transport });
  const exchange = new ExchangeClient({ transport, wallet });

  return { info, exchange, wallet };
}

/* ///////////////////////////////////////////////////////////////
                     READ POSITION
/////////////////////////////////////////////////////////////// */

/**
 * Get the current ETH-PERP position for the wallet.
 * Returns null if no position exists.
 */
export async function getPosition(
  config: HyperliquidConfig
): Promise<HyperliquidPosition | null> {
  const { info, wallet } = createClients(config);

  const state = await info.clearinghouseState({
    user: wallet.address,
  });

  // Find ETH position in the asset positions array
  const ethPosition = state.assetPositions.find(
    (pos: any) => {
      const coin = typeof pos === 'object' && pos?.position?.coin;
      return coin === 'ETH';
    }
  );

  if (!ethPosition || typeof ethPosition !== 'object') return null;

  const pos = (ethPosition as any).position;
  return {
    sizeEth: parseFloat(pos.szi),
    entryPx: parseFloat(pos.entryPx),
    unrealisedPnl: parseFloat(pos.unrealizedPnl),
    leverage: parseFloat(pos.leverage.value),
  };
}

/**
 * Get current ETH mid-price.
 */
export async function getEthPrice(
  config: HyperliquidConfig
): Promise<number> {
  const { info } = createClients(config);
  const mids = await info.allMids();
  const ethMid = mids["ETH"];
  if (!ethMid) throw new Error("ETH mid-price not found");
  return parseFloat(ethMid);
}

/* ///////////////////////////////////////////////////////////////
                     PLACE SHORT ORDER
/////////////////////////////////////////////////////////////// */

/**
 * Open or increase a short ETH-PERP position.
 *
 * Uses IOC (Immediate or Cancel) with a slippage-adjusted price
 * to simulate a market sell.
 *
 * @param config Hyperliquid config
 * @param sizeEth Size to short in ETH (positive number)
 */
export async function openShort(
  config: HyperliquidConfig,
  sizeEth: number
): Promise<HyperliquidTradeResult> {
  const { exchange, info } = createClients(config);

  // Get current ETH price for slippage calculation
  const mids = await info.allMids();
  const ethMid = parseFloat(mids["ETH"] ?? "0");
  if (ethMid === 0) {
    return { success: false, filledSize: 0, avgPrice: 0, error: "ETH mid-price not found" };
  }

  // IOC sell at (mid - slippage%) to ensure fill
  const limitPrice = ethMid * (1 - SLIPPAGE_PCT / 100);

  console.log(
    `[hyperliquid] Opening short: ${sizeEth} ETH @ limit $${limitPrice.toFixed(2)} (mid: $${ethMid.toFixed(2)})`
  );

  try {
    const result = await exchange.order({
      orders: [
        {
          a: ETH_ASSET_INDEX,
          b: false, // false = sell/short
          p: limitPrice.toFixed(1),
          s: sizeEth.toFixed(4),
          r: false, // not reduce-only
          t: { limit: { tif: "Ioc" } },
        },
      ],
      grouping: "na",
    });

    const statuses = (result as any)?.response?.data?.statuses;
    const status = statuses?.[0];
    if (status && typeof status === 'object' && 'filled' in status) {
      return {
        success: true,
        filledSize: parseFloat(status.filled.totalSz),
        avgPrice: parseFloat(status.filled.avgPx),
      };
    } else if (status && typeof status === 'object' && 'resting' in status) {
      return {
        success: true,
        filledSize: 0,
        avgPrice: 0,
      };
    } else {
      return {
        success: false,
        filledSize: 0,
        avgPrice: 0,
        error: JSON.stringify(status),
      };
    }
  } catch (err) {
    return {
      success: false,
      filledSize: 0,
      avgPrice: 0,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

/* ///////////////////////////////////////////////////////////////
                     CLOSE SHORT (REDUCE)
/////////////////////////////////////////////////////////////// */

/**
 * Reduce (partially close) a short ETH-PERP position.
 *
 * @param config Hyperliquid config
 * @param sizeEth Size to close in ETH (positive number)
 */
export async function reduceShort(
  config: HyperliquidConfig,
  sizeEth: number
): Promise<HyperliquidTradeResult> {
  const { exchange, info } = createClients(config);

  const mids = await info.allMids();
  const ethMid = parseFloat(mids["ETH"] ?? "0");
  if (ethMid === 0) {
    return { success: false, filledSize: 0, avgPrice: 0, error: "ETH mid-price not found" };
  }

  // IOC buy at (mid + slippage%) to ensure fill (closing a short = buying)
  const limitPrice = ethMid * (1 + SLIPPAGE_PCT / 100);

  console.log(
    `[hyperliquid] Reducing short: ${sizeEth} ETH @ limit $${limitPrice.toFixed(2)} (mid: $${ethMid.toFixed(2)})`
  );

  try {
    const result = await exchange.order({
      orders: [
        {
          a: ETH_ASSET_INDEX,
          b: true, // true = buy (closing short)
          p: limitPrice.toFixed(1),
          s: sizeEth.toFixed(4),
          r: true, // reduce-only
          t: { limit: { tif: "Ioc" } },
        },
      ],
      grouping: "na",
    });

    const statuses = (result as any)?.response?.data?.statuses;
    const status = statuses?.[0];
    if (status && typeof status === 'object' && 'filled' in status) {
      return {
        success: true,
        filledSize: parseFloat(status.filled.totalSz),
        avgPrice: parseFloat(status.filled.avgPx),
      };
    } else {
      return {
        success: false,
        filledSize: 0,
        avgPrice: 0,
        error: JSON.stringify(status),
      };
    }
  } catch (err) {
    return {
      success: false,
      filledSize: 0,
      avgPrice: 0,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

/* ///////////////////////////////////////////////////////////////
                  RESIZE TO TARGET NOTIONAL
/////////////////////////////////////////////////////////////// */

/**
 * Resize the short ETH-PERP position to match a target notional.
 * This is the main entry point for the keeper executor.
 *
 * @param config Hyperliquid config
 * @param targetSizeEth Target short size in ETH (positive number = short this much)
 * @returns Trade result
 */
export async function resizeShortToTarget(
  config: HyperliquidConfig,
  targetSizeEth: number
): Promise<HyperliquidTradeResult> {
  const currentPosition = await getPosition(config);
  const currentShort = currentPosition
    ? Math.abs(currentPosition.sizeEth)
    : 0;

  console.log(
    `[hyperliquid] Resize: current=${currentShort.toFixed(4)} ETH short → target=${targetSizeEth.toFixed(4)} ETH short`
  );

  const delta = targetSizeEth - currentShort;

  if (Math.abs(delta) < 0.001) {
    console.log("[hyperliquid] Position already at target — no trade needed");
    return { success: true, filledSize: 0, avgPrice: 0 };
  }

  if (delta > 0) {
    // Need MORE short — sell more ETH
    return openShort(config, delta);
  } else {
    // Need LESS short — buy back (reduce)
    return reduceShort(config, Math.abs(delta));
  }
}
