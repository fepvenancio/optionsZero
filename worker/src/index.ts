import { Hono } from "hono";
import { type Address, type Hex } from "viem";
import { runMonitorCycle, logResult, type MonitorResult } from "./monitor";
import { renderDashboard } from "./dashboard";
import { executeAll, type ExecutionResult } from "./executor";

/* ///////////////////////////////////////////////////////////////
                         ENV BINDINGS
/////////////////////////////////////////////////////////////// */

type Bindings = {
  ARBITRUM_RPC_URL: string;
  VAULT_ADDRESS: string;
  ADAPTER_ADDRESS: string;
  IMBALANCE_THRESHOLD_BPS: string;
  API_SECRET: string;
  KEEPER_PRIVATE_KEY: string;
  /** Hyperliquid wallet private key (optional — enables real trading). */
  HYPERLIQUID_PRIVATE_KEY?: string;
  /** Set to "true" for Hyperliquid testnet (default: mainnet). */
  HYPERLIQUID_TESTNET?: string;
  /** Address of the vault wallet on Hyperliquid (main account, not API wallet). */
  HYPERLIQUID_VAULT_ADDRESS?: string;
  /** 1inch API key for swap execution (set via wrangler secret put). */
  ONEINCH_API_KEY?: string;
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
    rpcUrl: env.ARBITRUM_RPC_URL,
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
        isTestnet: env.HYPERLIQUID_TESTNET === "true", // default to mainnet
        leverage: 25,
        maxPositionEth: 0.05, // ~$94 notional → ~$3.76 margin at 25x
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

/// GET /status — public vault state + HL position (all data is public)
app.get("/status", async (c) => {
  const config = buildMonitorConfig(c.env);
  const result = await runMonitorCycle(config);
  const serialised = serialiseResult(result) as Record<string, unknown>;

  // Fetch Hyperliquid position if key is configured
  if (c.env.HYPERLIQUID_PRIVATE_KEY) {
    try {
      // Use vault address if configured, otherwise derive from API key
      let hlAddress: string;
      if (c.env.HYPERLIQUID_VAULT_ADDRESS) {
        hlAddress = c.env.HYPERLIQUID_VAULT_ADDRESS;
      } else {
        const { privateKeyToAccount } = await import("viem/accounts");
        const account = privateKeyToAccount(c.env.HYPERLIQUID_PRIVATE_KEY as Hex);
        hlAddress = account.address;
      }
      const isTestnet = c.env.HYPERLIQUID_TESTNET === "true";
      const baseUrl = isTestnet
        ? "https://api.hyperliquid-testnet.xyz"
        : "https://api.hyperliquid.xyz";

      const hlRes = await fetch(`${baseUrl}/info`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          type: "clearinghouseState",
          user: hlAddress,
        }),
      });

      if (hlRes.ok) {
        const hlData = (await hlRes.json()) as Record<string, unknown>;
        const positions = hlData.assetPositions as Array<Record<string, unknown>> | undefined;
        const ethPos = positions?.find((p: Record<string, unknown>) => {
          const pos = p.position as Record<string, string> | undefined;
          return pos?.coin === "ETH";
        });

        if (ethPos) {
          const pos = ethPos.position as Record<string, string>;
          serialised.hlPosition = {
            szi: pos.szi ?? "0",
            entryPx: pos.entryPx ?? null,
            unrealizedPnl: pos.unrealizedPnl ?? "0",
            marginUsed: pos.marginUsed ?? "0",
            leverage: (pos as Record<string, unknown>).leverage ?? null,
          };
        } else {
          serialised.hlPosition = {
            szi: "0",
            entryPx: null,
            unrealizedPnl: "0",
            marginUsed: "0",
          };
        }

        serialised.hlAccount = {
          address: hlAddress,
          accountValue: (hlData.crossMarginSummary as Record<string, string>)?.accountValue ?? "0",
        };
      }
    } catch (err) {
      console.warn("[status] HL fetch error:", err);
    }
  }

  return c.json(serialised);
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
