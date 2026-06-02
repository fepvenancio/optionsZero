import { Hono } from "hono";
import { type Address, type Hex } from "viem";
import { runMonitorCycle, logResult, type MonitorResult } from "./monitor";
import { renderDashboard } from "./dashboard";
import { executeAll, type ExecutionResult } from "./executor";

/* ///////////////////////////////////////////////////////////////
                         ENV BINDINGS
/////////////////////////////////////////////////////////////// */

type Bindings = {
  SEPOLIA_RPC_URL: string;
  VAULT_ADDRESS: string;
  ADAPTER_ADDRESS: string;
  IMBALANCE_THRESHOLD_BPS: string;
  API_SECRET: string;
  KEEPER_PRIVATE_KEY: string;
  /** Hyperliquid wallet private key (optional — enables real trading). */
  HYPERLIQUID_PRIVATE_KEY?: string;
  /** Set to "true" for Hyperliquid testnet (default: testnet). */
  HYPERLIQUID_TESTNET?: string;
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

function serialiseExecution(results: ExecutionResult[]) {
  return results.map((r) => ({
    intent: r.intent.kind,
    txHash: r.txHash,
    success: r.success,
    error: r.error ?? null,
  }));
}

function buildMonitorConfig(env: Bindings) {
  return {
    rpcUrl: env.SEPOLIA_RPC_URL,
    vaultAddress: env.VAULT_ADDRESS as Address,
    adapterAddress: env.ADAPTER_ADDRESS as Address,
    imbalanceThresholdBps: parseInt(env.IMBALANCE_THRESHOLD_BPS, 10) || 100,
  };
}

function buildExecutorConfig(env: Bindings) {
  const base = {
    ...buildMonitorConfig(env),
    privateKey: env.KEEPER_PRIVATE_KEY as Hex,
  };

  // Attach Hyperliquid config if the key is provided.
  if (env.HYPERLIQUID_PRIVATE_KEY) {
    return {
      ...base,
      hyperliquid: {
        privateKey: env.HYPERLIQUID_PRIVATE_KEY as Hex,
        isTestnet: env.HYPERLIQUID_TESTNET !== "false", // default to testnet
      },
    };
  }

  return base;
}

/** Validate Bearer token against the API_SECRET. */
function isAuthorised(c: {
  req: { header: (name: string) => string | undefined };
  env: Bindings;
}): boolean {
  const auth = c.req.header("Authorization");
  if (!auth) return false;
  const token = auth.replace("Bearer ", "");
  return token === c.env.API_SECRET;
}

/* ///////////////////////////////////////////////////////////////
                          HONO APP
/////////////////////////////////////////////////////////////// */

const app = new Hono<{ Bindings: Bindings }>();

/// GET / — serve the live dashboard
app.get("/", (c) => {
  return c.html(renderDashboard());
});

/// GET /health — public health check
app.get("/health", (c) => {
  return c.json({ service: "optionszero-vault-monitor", status: "ok" });
});

/// GET /status — public vault state (all data is public on-chain)
app.get("/status", async (c) => {
  const config = buildMonitorConfig(c.env);
  const result = await runMonitorCycle(config);
  return c.json(serialiseResult(result));
});

/// GET /monitor — protected: read-only monitor cycle
app.get("/monitor", async (c) => {
  if (!isAuthorised(c)) {
    return c.json({ error: "Unauthorized" }, 401);
  }

  const config = buildMonitorConfig(c.env);
  const result = await runMonitorCycle(config);
  logResult(result);
  return c.json(serialiseResult(result));
});

/// POST /execute — protected: run monitor + execute any fired intents
app.post("/execute", async (c) => {
  if (!isAuthorised(c)) {
    return c.json({ error: "Unauthorized" }, 401);
  }

  const monitorConfig = buildMonitorConfig(c.env);
  const executorConfig = buildExecutorConfig(c.env);

  // Step 1: Monitor
  const result = await runMonitorCycle(monitorConfig);
  logResult(result);

  if (result.intents.length === 0) {
    return c.json({
      monitor: serialiseResult(result),
      executions: [],
      message: "No intents fired — vault is balanced",
    });
  }

  // Step 2: Execute
  const execResults = await executeAll(executorConfig, result.intents);

  return c.json({
    monitor: serialiseResult(result),
    executions: serialiseExecution(execResults),
  });
});

/* ///////////////////////////////////////////////////////////////
                     CLOUDFLARE EXPORTS
/////////////////////////////////////////////////////////////// */

export default {
  fetch: app.fetch,

  /**
   * Cron trigger handler — runs every 5 minutes.
   * Monitors vault state AND auto-executes any fired intents.
   */
  async scheduled(
    _event: ScheduledEvent,
    env: Bindings,
    ctx: ExecutionContext
  ): Promise<void> {
    const monitorConfig = buildMonitorConfig(env);
    const executorConfig = buildExecutorConfig(env);

    ctx.waitUntil(
      (async () => {
        try {
          // Step 1: Monitor
          const result = await runMonitorCycle(monitorConfig);
          logResult(result);

          if (result.intents.length === 0) {
            console.log("[cron] No intents — vault is balanced ✓");
            return;
          }

          // Step 2: Execute
          console.log(
            `[cron] ${result.intents.length} intent(s) fired — executing...`
          );
          const execResults = await executeAll(
            executorConfig,
            result.intents
          );

          for (const r of execResults) {
            if (r.success) {
              console.log(
                `[cron] ✅ ${r.intent.kind} executed: ${r.txHash}`
              );
            } else {
              console.error(
                `[cron] ❌ ${r.intent.kind} failed: ${r.error}`
              );
            }
          }
        } catch (err) {
          console.error("[cron] Monitor/execute cycle failed:", err);
        }
      })()
    );
  },
};
