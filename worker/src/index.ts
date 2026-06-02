import { Hono } from "hono";
import { type Address } from "viem";
import { runMonitorCycle, logResult, type MonitorResult } from "./monitor";

/* ///////////////////////////////////////////////////////////////
                         ENV BINDINGS
/////////////////////////////////////////////////////////////// */

type Bindings = {
  SEPOLIA_RPC_URL: string;
  VAULT_ADDRESS: string;
  ADAPTER_ADDRESS: string;
  IMBALANCE_THRESHOLD_BPS: string;
};

/* ///////////////////////////////////////////////////////////////
                           HELPERS
/////////////////////////////////////////////////////////////// */

/** Serialise BigInt values for JSON responses. */
function serialiseResult(result: MonitorResult) {
  return {
    totalAssetsWei: result.state.totalAssets.toString(),
    hedgedNotionalWei: result.state.hedgedNotional.toString(),
    pendingRedemptionWei: result.state.pendingRedemption.toString(),
    accruedFunding: result.state.accruedFunding.toString(),
    imbalanceBps: result.imbalanceBps,
    intents: result.intents.map((i) => ({
      kind: i.kind,
      direction: i.direction ?? null,
      sizeDeltaWei: i.sizeDeltaWei?.toString() ?? null,
      imbalanceBps: i.imbalanceBps ?? null,
      pendingSharesWei: i.pendingShares?.toString() ?? null,
    })),
    timestamp: result.timestamp,
  };
}

function buildConfig(env: Bindings) {
  return {
    rpcUrl: env.SEPOLIA_RPC_URL,
    vaultAddress: env.VAULT_ADDRESS as Address,
    adapterAddress: env.ADAPTER_ADDRESS as Address,
    imbalanceThresholdBps: parseInt(env.IMBALANCE_THRESHOLD_BPS, 10) || 100,
  };
}

/* ///////////////////////////////////////////////////////////////
                          HONO APP
/////////////////////////////////////////////////////////////// */

const app = new Hono<{ Bindings: Bindings }>();

/// GET / — health check
app.get("/", (c) => {
  return c.json({
    service: "optionszero-vault-monitor",
    status: "ok",
    vault: c.env.VAULT_ADDRESS,
    adapter: c.env.ADAPTER_ADDRESS,
    thresholdBps: c.env.IMBALANCE_THRESHOLD_BPS,
  });
});

/// GET /monitor — trigger a manual monitor cycle (for testing)
app.get("/monitor", async (c) => {
  const config = buildConfig(c.env);
  const result = await runMonitorCycle(config);
  logResult(result);
  return c.json(serialiseResult(result));
});

/* ///////////////////////////////////////////////////////////////
                     CLOUDFLARE EXPORTS
/////////////////////////////////////////////////////////////// */

export default {
  fetch: app.fetch,

  /** Cron trigger handler — runs every 5 minutes. */
  async scheduled(
    _event: ScheduledEvent,
    env: Bindings,
    ctx: ExecutionContext
  ): Promise<void> {
    const config = buildConfig(env);

    ctx.waitUntil(
      runMonitorCycle(config)
        .then((result) => {
          logResult(result);

          if (result.intents.length > 0) {
            console.log(
              `[cron] ${result.intents.length} intent(s) fired — ` +
                JSON.stringify(serialiseResult(result))
            );
          }
        })
        .catch((err) => {
          console.error("[cron] Monitor cycle failed:", err);
        })
    );
  },
};
