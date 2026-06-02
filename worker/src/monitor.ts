import { createPublicClient, http, formatEther, type Address } from "viem";
import { sepolia } from "viem/chains";
import { vaultAbi, adapterAbi } from "./abi";

/* ///////////////////////////////////////////////////////////////
                           TYPES
/////////////////////////////////////////////////////////////// */

export interface MonitorConfig {
  rpcUrl: string;
  vaultAddress: Address;
  adapterAddress: Address;
  imbalanceThresholdBps: number;
}

export interface VaultState {
  totalAssets: bigint;
  hedgedNotional: bigint;
  pendingRedemption: bigint;
  accruedFunding: bigint;
}

export type IntentKind = "RESIZE_SHORT_PERP" | "SETTLE_REDEMPTION_BATCH" | "NONE";

export interface MonitorResult {
  state: VaultState;
  imbalanceBps: number;
  intents: IntentFired[];
  timestamp: number;
}

export interface IntentFired {
  kind: IntentKind;
  direction?: "INCREASE_SHORT" | "DECREASE_SHORT";
  sizeDeltaWei?: bigint;
  imbalanceBps?: number;
  pendingShares?: bigint;
}

/* ///////////////////////////////////////////////////////////////
                        ON-CHAIN READS
/////////////////////////////////////////////////////////////// */

async function readVaultState(config: MonitorConfig): Promise<VaultState> {
  const client = createPublicClient({
    chain: sepolia,
    transport: http(config.rpcUrl),
  });

  // Fire all reads in parallel via multicall
  const [totalAssets, hedgedNotional, pendingRedemption, accruedFunding] =
    await Promise.all([
      client.readContract({
        address: config.vaultAddress,
        abi: vaultAbi,
        functionName: "totalAssets",
      }),
      client.readContract({
        address: config.adapterAddress,
        abi: adapterAbi,
        functionName: "totalHedgedNotional",
      }),
      client.readContract({
        address: config.vaultAddress,
        abi: vaultAbi,
        functionName: "totalPendingRedemption",
      }),
      client.readContract({
        address: config.adapterAddress,
        abi: adapterAbi,
        functionName: "accruedFunding",
      }),
    ]);

  return { totalAssets, hedgedNotional, pendingRedemption, accruedFunding };
}

/* ///////////////////////////////////////////////////////////////
                     TRIGGER EVALUATION
/////////////////////////////////////////////////////////////// */

function evaluateTriggers(
  state: VaultState,
  thresholdBps: number
): IntentFired[] {
  const intents: IntentFired[] = [];

  // ── Trigger 1: Size Imbalance ──────────────────────────────
  if (state.totalAssets > 0n) {
    const delta = state.totalAssets - state.hedgedNotional;
    const absDelta = delta < 0n ? -delta : delta;

    // imbalanceBps = |delta| * 10000 / totalAssets
    const imbalanceBps = Number((absDelta * 10_000n) / state.totalAssets);

    if (imbalanceBps > thresholdBps) {
      intents.push({
        kind: "RESIZE_SHORT_PERP",
        direction: delta > 0n ? "INCREASE_SHORT" : "DECREASE_SHORT",
        sizeDeltaWei: delta,
        imbalanceBps,
      });
    }
  }

  // ── Trigger 2: Pending Redemption Batch ────────────────────
  if (state.pendingRedemption > 0n) {
    intents.push({
      kind: "SETTLE_REDEMPTION_BATCH",
      pendingShares: state.pendingRedemption,
    });
  }

  return intents;
}

/* ///////////////////////////////////////////////////////////////
                        PUBLIC API
/////////////////////////////////////////////////////////////// */

export async function runMonitorCycle(
  config: MonitorConfig
): Promise<MonitorResult> {
  const state = await readVaultState(config);
  const intents = evaluateTriggers(state, config.imbalanceThresholdBps);

  // Compute summary imbalance
  let imbalanceBps = 0;
  if (state.totalAssets > 0n) {
    const absDelta =
      state.totalAssets > state.hedgedNotional
        ? state.totalAssets - state.hedgedNotional
        : state.hedgedNotional - state.totalAssets;
    imbalanceBps = Number((absDelta * 10_000n) / state.totalAssets);
  }

  return {
    state,
    imbalanceBps,
    intents,
    timestamp: Date.now(),
  };
}

/* ///////////////////////////////////////////////////////////////
                        LOG HELPERS
/////////////////////////////////////////////////////////////// */

export function logResult(result: MonitorResult): void {
  const { state, imbalanceBps, intents } = result;

  console.log(
    `[vault-monitor] totalAssets=${formatEther(state.totalAssets)} ` +
      `hedgedNotional=${formatEther(state.hedgedNotional)} ` +
      `pendingRedemption=${formatEther(state.pendingRedemption)} ` +
      `accruedFunding=${state.accruedFunding.toString()} ` +
      `imbalanceBps=${imbalanceBps}`
  );

  if (intents.length === 0) {
    console.log("[vault-monitor] No intents fired — vault is balanced ✓");
    return;
  }

  for (const intent of intents) {
    if (intent.kind === "RESIZE_SHORT_PERP") {
      console.log(
        `[vault-monitor] INTENT: ${intent.kind} ` +
          `direction=${intent.direction} ` +
          `sizeDelta=${formatEther(intent.sizeDeltaWei!)} ETH ` +
          `imbalance=${intent.imbalanceBps}bps`
      );
    } else {
      console.log(
        `[vault-monitor] INTENT: ${intent.kind} ` +
          `pendingShares=${formatEther(intent.pendingShares!)} ETH`
      );
    }
  }
}
