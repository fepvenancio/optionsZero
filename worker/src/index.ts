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
  API_SECRET: string;
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

/** Validate Bearer token against the API_SECRET. */
function isAuthorised(c: { req: { header: (name: string) => string | undefined }; env: Bindings }): boolean {
  const auth = c.req.header("Authorization");
  if (!auth) return false;
  const token = auth.replace("Bearer ", "");
  return token === c.env.API_SECRET;
}

/* ///////////////////////////////////////////////////////////////
                          HONO APP
/////////////////////////////////////////////////////////////// */

const app = new Hono<{ Bindings: Bindings }>();

/// GET / — public health check (no sensitive data)
app.get("/", (c) => {
  return c.json({
    service: "optionszero-vault-monitor",
    status: "ok",
  });
});

/// GET /monitor — protected manual trigger
app.get("/monitor", async (c) => {
  if (!isAuthorised(c)) {
    return c.json({ error: "Unauthorized" }, 401);
  }

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

  /** Cron trigger handler — runs every 5 minutes (internal, no auth needed). */
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
