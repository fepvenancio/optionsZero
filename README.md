# OptionZero

> **Delta-neutral synthetic fiat vault — POC**
>
> Accepts wstETH deposits → strips ETH price delta via a 1× short ETH perpetual
> future on Hyperliquid → tranches risk into a stable **P token** (ozP) and a
> yield-bearing risky **N token** (ozN) → routes rebalancing and batch-settlement
> intents cross-chain via the NEAR Intents solver bus.

Read [`docs/01_metalearning_map.md`](docs/01_metalearning_map.md) for the full architecture.

---

## How it Works

```
User deposits wstETH
        │
        ▼
   Vault (ERC-4626)
        │  calls split()
        ▼
   Trancher
        │  coverage = min(1, perpNotional / TVL)
        │  pMinted  = shares × coverage
        │  nMinted  = shares − pMinted
        ▼
   ozP (stable tranche)   ozN (yield/risk tranche)
```

The vault maintains a **1× short ETH perp** on Hyperliquid (constant delta = −1.0).
Positive funding rate → vault earns, credited to N token holders.
Negative funding rate → vault pays, absorbed by the N tranche yield buffer.

When users exit, they enter a **3-phase async batch queue** to allow the
cross-chain perp position to be unwound before wstETH is bridged back:

| Phase | Who calls | What happens |
|---|---|---|
| **1 — Request** | User | `requestRedeem()` — P+N burned, shares locked, assets snapshotted |
| **2 — Settle** | CRE Keeper / NEAR solver → Hyperliquid → bridge | `closeBatch()` + `settleBatch()` — perp downsized, wstETH bridged back |
| **3 — Claim** | User | `claimRedeemedAssets()` — pro-rata wstETH released |

---

## Quick Start

### Prerequisites

| Tool | Version |
|---|---|
| [Foundry](https://getfoundry.sh) | `forge 1.6+` |
| [Go](https://go.dev) | `1.25+` |
| [CRE CLI](https://docs.chain.link/cre) | Latest |

### Install dependencies

```bash
cd contracts && forge install
```

### Run tests

```bash
# Solidity — 117 tests across 7 suites
cd contracts
forge test --fuzz-runs 500 -vv
```

Expected output:

```
Ran 7 test suites: 117 tests passed, 0 failed
```

### Deploy to local Anvil

```bash
# Terminal 1: local node
anvil

# Terminal 2: deploy full stack
cd contracts
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv
```

Source the printed env vars, then run the simulation:

```bash
forge script script/Simulate.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vvvv
```

### Deploy to Sepolia (Ledger)

```bash
cd contracts
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --account <ledger-account> \
  --sender  <your-address> \
  --broadcast
```

#### Live Sepolia deployment

| Contract | Address |
|---|---|
| `MockWstETH` | `0x67B01481B9bAC7d0d4dc08473956FfAb91e08DDc` |
| `Vault` | `0x43A7bbbd3ad6D4F7a7e3D8277D6271f9C9f8cffD` |
| `Trancher` | `0x3Fa9b5033dD2Edb7e598834587fF7EA989fA55D4` |
| `MockPerpAdapter` | `0x343F8BF65EEA92b067b04431f4c579CB6276Ad83` |
| `PToken (ozP)` | `0x897c2ce435f80e144Ee6E02E9E2cC5B4E6d8b204` |
| `NToken (ozN)` | `0x53dFCDf660e386bb8c01a058a3BC2f4773eDbC87` |
| `YieldAccumulator` | `0xc01f7DA356215254a0598eD5edD94a228ec60012` |
| `IntentEncoder` | `0xb65C2d24591D0A12Bc650AE336e9EA2964e2b102` |

---

## CRE Vault Monitor

The off-chain monitor runs as a **Chainlink CRE** (Compute Runtime Environment)
cron workflow, compiled to WASM and deployed to a Decentralised Oracle Network
(DON). It watches Vault and MockPerpAdapter state on Sepolia and fires ERC-7683
intents into `intents.testnet` when either trigger condition is met.

| Trigger | Condition | Intent emitted |
|---|---|---|
| **Size imbalance** | `\|TVL − perpNotional\| / TVL > 1%` | `RESIZE_SHORT_PERP` |
| **Pending batch** | `totalPendingRedemption > 0` | `SETTLE_REDEMPTION_BATCH` |

### Simulate locally

```bash
cd cre
cre workflow simulate vault-monitor --target staging-settings
```

### Deploy to DON

```bash
cre account access
cre workflow deploy vault-monitor --target staging-settings
```

---

## Cloudflare Worker Monitor

A **Cloudflare Worker** provides a lightweight, immediately-available execution
layer for the same monitoring logic while CRE DON access is pending.

- **Cron trigger**: `*/5 * * * *` (every 5 minutes)
- **Manual trigger**: `GET /monitor` (Bearer token required)
- **Health check**: `GET /` (public, no sensitive data)
- **Stack**: Hono + viem + TypeScript on Cloudflare Workers

### Setup

```bash
cd worker
pnpm install

# Set secrets (never stored in code)
npx wrangler secret put SEPOLIA_RPC_URL
npx wrangler secret put API_SECRET

# Deploy
pnpm deploy
```

### Manual query

```bash
curl -H "Authorization: Bearer $API_SECRET" \
  https://<your-worker>.workers.dev/monitor
```

### Security

- **Read-only**: The worker only calls `view` functions. It holds no private keys
  and cannot sign transactions or modify on-chain state.
- **Auth-protected**: The `/monitor` endpoint requires a Bearer token (`API_SECRET`).
  Unauthenticated requests return 401.
- **Secrets**: `SEPOLIA_RPC_URL` and `API_SECRET` are stored in Cloudflare's
  encrypted secret store, never in source code.

---

## Project Structure

```
optionsZero/
│
├── contracts/                         ← Foundry project
│   ├── src/
│   │   ├── core/
│   │   │   ├── Vault.sol             ← ERC-4626 vault + async batch exit
│   │   │   ├── Trancher.sol          ← P/N split·merge math
│   │   │   ├── YieldAccumulator.sol  ← Funding rate yield accounting
│   │   │   └── BatchTypes.sol         ← RedemptionRequest · BatchInfo structs
│   │   ├── tokens/
│   │   │   ├── PToken.sol             ← ozP — stable tranche ERC-20
│   │   │   └── NToken.sol             ← ozN — risky tranche ERC-20
│   │   ├── hedge/
│   │   │   ├── IPerpAdapter.sol       ← Perp venue abstraction interface
│   │   │   └── MockPerpAdapter.sol    ← Configurable POC stub (flat −1.0 delta)
│   │   ├── oracles/
│   │   │   └── IPriceFeed.sol         ← Oracle interface (wstETH/USD rate)
│   │   ├── intents/
│   │   │   └── IntentEncoder.sol      ← ERC-7683 CrossChainOrder ABI helpers
│   │   └── interfaces/
│   │       ├── IVault.sol            ← Full vault interface (events + errors)
│   │       └── ITrancher.sol
│   ├── test/
│   │   ├── unit/
│   │   │   ├── VaultBatch.unit.t.sol   ← Async batch lifecycle (13 tests + fuzz)
│   │   │   ├── VaultSecurity.unit.t.sol← Security model: allowance, cancel, slippage (26 tests + fuzz)
│   │   │   ├── VaultRegression.t.sol   ← Regression guards (9 tests)
│   │   │   ├── Trancher.t.sol          ← Split/merge invariants (18 tests)
│   │   │   └── Tokens.t.sol             ← Token access control (15 tests)
│   │   └── integration/
│   │       ├── OptionZero.t.sol       ← Full stack integration (7 tests)
│   │       └── E2E.t.sol              ← End-to-end flows (8 tests)
│   └── script/
│       ├── Deploy.s.sol               ← Full deployment script
│       └── Simulate.s.sol             ← Rebalance simulation
│
├── cre/                               ← Chainlink CRE project
│   ├── vault-monitor/
│   │   ├── main.go                    ← CRE workflow entry point
│   │   ├── workflow.go                ← Monitor logic: triggers + intent builder
│   │   ├── workflow_test.go           ← Unit tests
│   │   ├── workflow.yaml              ← CRE workflow definition
│   │   ├── config.staging.json        ← Staging DON settings
│   │   └── config.production.json     ← Production DON settings
│   ├── contracts/                     ← On-chain bindings for CRE
│   ├── go.mod
│   ├── go.sum
│   ├── project.yaml                   ← CRE project manifest
│   └── secrets.yaml                   ← Secret references (never plaintext)
│
├── worker/                            ← Cloudflare Worker monitor
│   ├── src/
│   │   ├── index.ts                   ← Hono app + cron handler
│   │   ├── monitor.ts                 ← Core logic: on-chain reads + trigger eval
│   │   └── abi.ts                     ← Vault + Adapter ABI fragments
│   ├── wrangler.toml                  ← Worker config + cron schedule
│   ├── package.json
│   └── tsconfig.json
│
└── docs/
    └── 01_metalearning_map.md         ← Full architecture reference
```

---

## Key Contracts

| Contract | Role |
|---|---|
| [`Vault`](contracts/src/core/Vault.sol) | ERC-4626 vault. User entry point. Holds wstETH. Manages the 3-phase async exit lifecycle (`requestRedeem` / `closeBatch` / `settleBatch` / `claimRedeemedAssets`). |
| [`Trancher`](contracts/src/core/Trancher.sol) | Computes P/N split from perp coverage ratio. Sole minter/burner of ozP and ozN. |
| [`YieldAccumulator`](contracts/src/core/YieldAccumulator.sol) | Tracks accrued funding rate PnL. Settles funding from yield budget. |
| [`BatchTypes`](contracts/src/core/BatchTypes.sol) | Structs: `RedemptionRequest` (per-user) and `BatchInfo` (per-batch). |
| [`IPerpAdapter`](contracts/src/hedge/IPerpAdapter.sol) | Perp venue interface: `currentDelta()`, `totalHedgedNotional()`, `accruedFunding()`, position lifecycle. |
| [`MockPerpAdapter`](contracts/src/hedge/MockPerpAdapter.sol) | POC stub. Always returns δ = −1.0e18. Configurable funding rate per block. ERC-7201 namespaced storage. |

---

## POC Boundaries

Explicitly out of scope:

1. **Real oracle** — `IPriceFeed` is an interface only. No live Chainlink adapter deployed.
2. **Real perp venue** — `MockPerpAdapter` only. No live Hyperliquid adapter.
3. **CRE production deployment** — The CRE workflow runs against staging DON settings. Production DON deployment requires Chainlink node operator onboarding.
4. **Emergency pause / governance** — Thresholds are hardcoded constants.
5. **ozP secondary market peg** — No Curve/Balancer pool. Soft peg only.
6. **Production batch accounting** — `batch.totalAssetsLocked` used for pro-rata; CRE keeper uses `totalPendingRedemption` as a POC approximation of assets to bridge.
