# OptionZero

> **Delta-neutral synthetic fiat vault — Proof of Concept**
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
| **2 — Settle** | Gelato W3F → NEAR solver → Hyperliquid → bridge | `closeBatch()` + `settleBatch()` — perp downsized, wstETH bridged back |
| **3 — Claim** | User | `claimRedeemedAssets()` — pro-rata wstETH released |

---

## Quick Start

### Prerequisites

| Tool | Version |
|---|---|
| [Foundry](https://getfoundry.sh) | `forge 1.6+` |
| [pnpm](https://pnpm.io) | `9+` |
| [Anvil](https://book.getfoundry.sh/anvil/) | Ships with Foundry |

### Install dependencies

```bash
# Solidity
cd contracts && forge install

# Gelato Web3 Function
cd ../w3f && pnpm install
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
| `Vault` | `0x43A7bbbd3ad6D4F7a7e3D8277D6271f9C9f8cffD` |
| `Trancher` | `0x3Fa9b5033dD2Edb7e598834587fF7EA989fA55D4` |
| `MockPerpAdapter` | `0x343F8BF65EEA92b067b04431f4c579CB6276Ad83` |
| `PToken (ozP)` | `0x897c2ce435f80e144Ee6E02E9E2cC5B4E6d8b204` |
| `NToken (ozN)` | `0x53dFCDf660e386bb8c01a058a3BC2f4773eDbC87` |
| `YieldAccumulator` | `0xc01f7DA356215254a0598eD5edD94a228ec60012` |
| `IntentEncoder` | `0xb65C2d24591D0A12Bc650AE336e9EA2964e2b102` |
| `MockWstETH` | `0x67B01481B9bAC7d0d4dc08473956FfAb91e08DDc` |

### Run the Gelato Web3 Function locally

```bash
cd w3f

# Type-check
pnpm lint

# Run against Sepolia with Gelato test runner
npx @gelatonetwork/web3-functions-sdk@latest test src/index.ts \
  --show-logs \
  --user-args '{"vaultAddress":"0x67ecf07E977cd869b1B407312647116101e3DFb4","adapterAddress":"0x007CeBEfE42E75a9aCc132ad337771A207f9F3f9","imbalanceThresholdBps":100,"batchWindowBlocks":300}'
```

Secrets (`NEAR_ACCOUNT_ID`, `NEAR_PRIVATE_KEY`, `NEAR_RPC_URL`) are managed via the [Gelato App dashboard](https://app.gelato.network) — never stored in files.

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
│   │   │   └── IOptionsPricer.sol     ← Oracle interface (wstETH/USD rate)
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
├── w3f/                               ← Gelato Web3 Function (TypeScript)
│   ├── src/
│   │   └── index.ts                   ← W3F handler: 2-trigger monitor + NEAR submission
│   ├── schema.json                    ← Gelato userArgs schema
│   └── package.json
│
├── scripts/
│   └── run_e2e.sh                     ← Local end-to-end simulation script
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

## Gelato Web3 Function

The [`w3f/src/index.ts`](w3f/src/index.ts) is the off-chain monitor. It runs on Gelato's cron infrastructure and fires two types of ERC-7683 intents into `intents.testnet`:

| Trigger | Condition | Intent emitted |
|---|---|---|
| **Size imbalance** | `\|TVL − perpNotional\| / TVL > imbalanceThresholdBps / 10_000` | `RESIZE_SHORT_PERP` |
| **Pending batch** | `totalPendingRedemption > 0` AND batch open `≥ batchWindowBlocks` | `SETTLE_REDEMPTION_BATCH` |

Gelato W3F `userArgs` (set in the Gelato dashboard):

| Arg | Default | Description |
|---|---|---|
| `vaultAddress` | — | Deployed `Vault` address (required) |
| `adapterAddress` | — | Deployed `MockPerpAdapter` address (required) |
| `imbalanceThresholdBps` | `100` | Size imbalance threshold in basis points (100 = 1%) |
| `batchWindowBlocks` | `300` | Blocks a batch must be open before settlement fires (≈ 1 h) |

Gelato secrets (set in the Gelato dashboard, never in files):

| Secret | Description |
|---|---|
| `NEAR_ACCOUNT_ID` | NEAR testnet account that submits to `intents.testnet` |
| `NEAR_PRIVATE_KEY` | ed25519 private key for that account (`ed25519:...`) |
| `NEAR_RPC_URL` | NEAR RPC endpoint (default: `https://rpc.testnet.near.org`) |

---

## POC Boundaries

Explicitly out of scope:

1. **Real oracle** — `IOptionsPricer` is an interface only. No live Chainlink adapter.
2. **Real perp venue** — `MockPerpAdapter` only. No live Hyperliquid adapter.
3. **NEAR MPC signing** — W3F uses a plain ed25519 key; production should use NEAR Chain Signatures for MPC-based threshold signing.
4. **Emergency pause / governance** — Thresholds are hardcoded constants.
5. **ozP secondary market peg** — No Curve/Balancer pool. Soft peg only.
6. **Production batch accounting** — `batch.totalAssetsLocked` used for pro-rata; W3F uses `totalPendingRedemption` as a POC approximation of assets to bridge.
