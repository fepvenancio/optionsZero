# OptionZero — Architecture & Design Reference

## docs/01_metalearning_map.md

> **Purpose:** Canonical entry point for any engineer, researcher, or auditor
> approaching OptionZero for the first time.
> Answers: **Why** does this exist? **What** are its components? **How** do
> they interact? **Where** is specific logic?

---

## 1 — Why: The Problem This System Solves

Traditional stablecoins face a capital-efficiency trilemma:

| Archetype | Example | Weakness |
|---|---|---|
| Fiat-backed | USDC | Centralised, custodial |
| Crypto-overcollateralised | DAI | Capital-inefficient |
| Algorithmic | UST | Peg fragility under reflexive sell pressure |

**OptionZero's bet:** Liquid staking yield from wstETH (~4% APR) is a
structurally predictable cash flow. If we can continuously hedge away the ETH
price exposure while keeping the yield, the collateral pool becomes a synthetic
dollar — fully backed, yield-generating, and decentralised.

The hedge is a **1× short ETH perpetual future** on Hyperliquid:

- Delta is structurally **−1.0** (constant, no gamma drift).
- The short earns **funding rate** when longs pay shorts (the common case in
  bull markets). This funding income accrues to N token holders.
- Rebalancing is only needed when **TVL changes** (deposits / withdrawals shift
  the required position size), not when ETH price moves.

```
Viability condition:
  wstETH_yield_APR + avg_funding_income > bridge_costs + slippage
```

---

## 2 — Mental Model: The Three Layers

```
┌──────────────────────────────────────────────────────────────┐
│                     USER / INTEGRATOR                        │
│   deposit wstETH → receive ozP + ozN                         │
│   exit: requestRedeem() → wait for batch → claimAssets()     │
└──────────────────────┬───────────────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────────────┐
│                    ON-CHAIN LAYER                            │
│                                                              │
│  ┌─────────────┐  split/merge   ┌────────────────────────┐  │
│  │   Vault    │ ◄────────────► │      Trancher         │  │
│  │ (ERC-4626)  │                │  ozP ← stable tranche  │  │
│  │  wstETH     │                │  ozN ← risky tranche   │  │
│  │ + batch     │                └────────────────────────┘  │
│  │   queue     │                                             │
│  └──────┬──────┘                ┌────────────────────────┐  │
│         │                       │  YieldAccumulator     │  │
│         │ reads notional /      │  funding rate budget   │  │
│         │ accrued funding       └────────────────────────┘  │
│         ▼                                                    │
│  ┌───────────────────┐  ┌──────────────────────────────┐    │
│  │  IPerpAdapter     │  │  IntentEncoder               │    │
│  │  MockPerpAdapter  │  │  (ERC-7683 helpers)          │    │
│  └───────────────────┘  └──────────────────────────────┘    │
└──────────────────────┬───────────────────────────────────────┘
                       │  IntentRequested event
┌──────────────────────▼───────────────────────────────────────┐
│         OFF-CHAIN LAYER  (Gelato Web3 Function)              │
│                                                              │
│  w3f/src/index.ts  (cron-triggered)                          │
│    ├─ Trigger 1: size imbalance  → RESIZE_SHORT_PERP         │
│    └─ Trigger 2: pending batch   → SETTLE_REDEMPTION_BATCH   │
│                                                              │
│  Builds CrossChainOrder JSON → submitToNear()                │
│  (near-api-js v3 account.functionCall to intents.testnet)    │
└──────────────────────┬───────────────────────────────────────┘
                       │
┌──────────────────────▼───────────────────────────────────────┐
│             NEAR INTENTS SOLVER BUS                          │
│  Signed ERC-7683 intent → competitive solver network         │
│  → Hyperliquid resize / bridge → Vault.settleBatch()        │
└──────────────────────────────────────────────────────────────┘
```

---

## 3 — What: Component Glossary

### On-chain (Solidity)

| Component | File | Role |
|---|---|---|
| **Vault** | `src/core/Vault.sol` | ERC-4626 vault. User entry point. Holds wstETH. Manages the 3-phase async exit lifecycle. Emits `IntentRequested` when TVL/notional diverge. |
| **Trancher** | `src/core/Trancher.sol` | Computes P/N split ratio from perp coverage. Sole minter/burner of ozP and ozN. Enforces the `pSupply + nSupply == activeSupply` invariant. |
| **YieldAccumulator** | `src/core/YieldAccumulator.sol` | Snapshots wstETH rate delta to track LST yield budget. Settles accrued funding from that budget. Reverts when budget is exhausted. |
| **BatchTypes** | `src/core/BatchTypes.sol` | Shared structs: `RedemptionRequest` (per-user) and `BatchInfo` (per-batch). `RequestStatus` enum: PENDING → CLAIMED. |
| **PToken (ozP)** | `src/tokens/PToken.sol` | ERC-20. Stable tranche. Accounting soft peg to USD. Mint/burn by Trancher only. |
| **NToken (ozN)** | `src/tokens/NToken.sol` | ERC-20. Risky tranche. Absorbs tail risk, earns residual funding income. Mint/burn by Trancher only. |
| **IPerpAdapter** | `src/hedge/IPerpAdapter.sol` | Interface for any perp venue. Exposes `currentDelta()`, `totalHedgedNotional()`, `accruedFunding()`, `fundingRatePerBlock()`, position lifecycle. |
| **MockPerpAdapter** | `src/hedge/MockPerpAdapter.sol` | POC stub. Always returns δ = −1.0e18. Configurable `fundingRatePerBlock` (signed). ERC-7201 namespaced storage. Used exclusively in tests and Anvil. |
| **IOptionsPricer** | `src/oracles/IOptionsPricer.sol` | Oracle interface. Returns ETH/USD price and wstETH conversion rate. |
| **IntentEncoder** | `src/intents/IntentEncoder.sol` | Stateless ABI encoder. Produces ERC-7683 `CrossChainOrder` bytes from rebalance/settlement parameters. |
| **IVault** | `src/interfaces/IVault.sol` | Complete vault interface. Declares all events (including batch lifecycle) and custom errors. |

### Off-chain (Gelato Web3 Function)

| Module | File | Role |
|---|---|---|
| **W3F handler** | `w3f/src/index.ts` | Cron-triggered entry point. Reads Vault and MockPerpAdapter state via `ethers.Contract`. Evaluates both triggers and submits intents to `intents.testnet`. |
| **submitToNear** | `w3f/src/index.ts` | Inline async function. Uses `near-api-js` v3 `account.functionCall()` for ed25519 signing, borsh serialisation and broadcast. |
| **schema.json** | `w3f/schema.json` | Gelato userArgs schema. Declares `vaultAddress`, `adapterAddress`, `imbalanceThresholdBps`, `batchWindowBlocks`. |

---

## 4 — How: Key Invariants

### 4.1 The P/N Supply Invariant

At any point when no redemptions are pending:

```
ozP.totalSupply() + ozN.totalSupply() == Vault.totalSupply()
```

During an open batch (between `requestRedeem` and `settleBatch`), P+N are
burned at request time but vault shares are not burned until settlement.
The correct extended invariant is:

```
ozP.totalSupply() + ozN.totalSupply()
  == Vault.totalSupply() − Vault.totalPendingRedemption()
```

Enforced by `Trancher.split()` (mints `pMinted + nMinted = shares`) and
`Trancher.merge()` (burns from user's personal balance, not global ratios —
see §6 for why this matters).

### 4.2 The Hedge Coverage Equation

```
coverage  = min(1e18,  adapter.totalHedgedNotional() × 1e18 / totalVaultShares)
pMinted   = shares × coverage / 1e18
nMinted   = shares − pMinted
```

- **`coverage = 1e18`** (100%): all new deposits are P tokens (fully stable).
- **`coverage = 0`**: all new deposits are N tokens (no hedge active).
- **Vault genesis**: empty vault → coverage defaults to 1e18 for the first depositor.

### 4.3 The Rebalance Trigger (Size Imbalance)

```
imbalance = |Vault.totalDepositedAssets() − adapter.totalHedgedNotional()|
threshold = Vault.totalDepositedAssets() × IMBALANCE_THRESHOLD_BPS / 10_000

if imbalance > threshold:
  sizeDelta = int256(totalDepositedAssets) − int256(totalHedgedNotional)
  emit IntentRequested(sizeDelta, block.timestamp)
  // positive sizeDelta → increase short (vault under-hedged)
  // negative sizeDelta → decrease short (vault over-hedged)
```

Note: price moves do **not** trigger a rebalance because δ = −1.0 is constant.
Only TVL changes (deposit / withdraw) move the required notional.

### 4.4 The Async Exit Lifecycle

```
Phase 1 — requestRedeem(shares, receiver, owner, pAmount, nAmount)
  ├── Trancher.merge(shares, pAmount, nAmount)    ← P+N burned NOW
  ├── _spendAllowance(owner, msg.sender, shares)   ← allowance guard for delegated calls
  ├── vault shares transferred to vault contract   ← locked
  ├── assetsLocked = previewRedeem(shares)         ← snapshotted NOW
  └── request added to currentBatch

Phase 2a — closeBatch()    [settler only]
  └── batch.isClosed = true; opens a new batch

Phase 2b — settleBatch(batchId, assetsReturned)    [settler only]
  ├── wstETH transferred from settler to vault
  ├── locked shares burned                         ← supply decreases
  └── batch.isSettled = true; assetsReturned stored

Phase 3 — claimRedeemedAssets(requestId)    [request owner]
  ├── pro-rata share: assetsReturned × myAssetsLocked / batch.totalAssetsLocked
  └── wstETH transferred to receiver; request marked CLAIMED
```

The snapshot of `assetsLocked` at request time (not settlement time) prevents
bridge-delay yield leakage: exiting users lock in their exchange rate
immediately, regardless of how long the bridge takes.

The `_spendAllowance` guard ensures that only the owner or an explicitly
approved operator can submit a redemption request on behalf of a wallet.

### 4.5 The Funding Rate Budget

```
fundingAccrued  = fundingRatePerBlock × blocks × totalHedgedNotional / 1e18

if fundingAccrued > 0:
  totalYieldAccumulated += fundingAccrued     ← vault earns
else:
  budget_remaining = totalYieldAccumulated − totalPremiumConsumed
  if budget_remaining < |fundingAccrued|:
    revert YieldAccumulator_InsufficientBudget ← circuit breaker
```

---

## 5 — Where: Navigation Map

```
optionsZero/
│
├── contracts/                         ← Foundry project
│   ├── src/
│   │   ├── core/
│   │   │   ├── Vault.sol             ← Primary vault logic
│   │   │   ├── Trancher.sol          ← P/N split·merge
│   │   │   ├── YieldAccumulator.sol  ← Funding rate accounting
│   │   │   └── BatchTypes.sol         ← Batch structs
│   │   ├── tokens/
│   │   │   ├── PToken.sol             ← ozP
│   │   │   └── NToken.sol             ← ozN
│   │   ├── hedge/
│   │   │   ├── IPerpAdapter.sol       ← Perp venue interface
│   │   │   └── MockPerpAdapter.sol    ← POC stub
│   │   ├── oracles/
│   │   │   └── IOptionsPricer.sol     ← Oracle interface
│   │   ├── intents/
│   │   │   └── IntentEncoder.sol      ← ERC-7683 helpers
│   │   └── interfaces/
│   │       ├── IVault.sol
│   │       └── ITrancher.sol
│   ├── test/
│   │   ├── unit/
│   │   │   ├── VaultBatch.unit.t.sol    ← Async batch lifecycle (13 tests + fuzz)
│   │   │   ├── VaultSecurity.unit.t.sol ← Security model: allowance, cancel, slippage (26 tests + fuzz)
│   │   │   ├── VaultRegression.t.sol    ← Regression guards (9 tests)
│   │   │   ├── Trancher.t.sol           ← Split/merge invariants (18 tests)
│   │   │   └── Tokens.t.sol              ← Token access control (15 tests)
│   │   └── integration/
│   │       ├── OptionZero.t.sol       ← Full stack (7 tests)
│   │       └── E2E.t.sol              ← End-to-end flows (8 tests)
│   └── script/
│       ├── Deploy.s.sol
│       └── Simulate.s.sol
│
├── w3f/                               ← Gelato Web3 Function
│   ├── src/
│   │   └── index.ts                   ← W3F handler: monitor + NEAR submission
│   ├── schema.json                    ← Gelato userArgs schema
│   └── package.json
│
├── docs/
│   └── 01_metalearning_map.md         ← THIS FILE
│
└── scripts/
    └── run_e2e.sh                     ← Local end-to-end simulation script
```

---

## 6 — Key Design Decisions & Rationale

| Decision | Rationale |
|---|---|
| **Perps over options** | A 1× short perp has constant δ = −1.0 with zero gamma. No rolling cost, no Gamma bleed, no vol-dependency. Rebalancing only triggers on TVL change — dramatically simpler than managing rolling DITM calls. |
| **Personal-balance merge (not global-ratio)** | Earlier design computed burned P/N from global supply ratios, causing the "Portfolio Lockup Flaw": users with only P tokens (full coverage) received N burns on exit if the aggregate pool had N tokens. Fixed by burning from the user's actual per-wallet P/N balances. |
| **Async batch exit (KAM pattern)** | Atomic redemption is impossible when the perp position lives on another chain. The 3-phase queue (Request → Settle → Claim) decouples user UX from cross-chain bridge latency. Modelled after KAM's batch processing architecture. |
| **assetsLocked snapshotted at request time** | Prevents bridge-delay yield leakage. If snapshot were at settlement, exiting users would silently earn yield during the bridge window that should belong to remaining depositors. |
| **`_spendAllowance` in requestRedeem** | Prevents an attacker from locking a victim's funds by calling `requestRedeem(victim, attacker, victim, ...)` without approval. Mirrors ERC-4626 `redeem` semantics. |
| **wstETH over stETH** | stETH rebases daily, breaking ERC-4626 share accounting. wstETH holds shares; yield accrues as the exchange rate rises. |
| **Solady ERC4626 base** | Virtual-offset inflation attack protection built-in (no dead shares needed). Gas-optimised. Battle-tested. |
| **ERC-7201 namespaced storage** | Future-proofs for UUPS upgradeability without storage collisions. Good engineering practice even in immutable POC. |
| **Gelato W3F over Rust daemon** | Serverless execution model — no persistent process to manage, no key file on disk, secrets stay in Gelato's encrypted vault, cron scheduling included. Dramatically simpler ops. |
| **near-api-js v3 in W3F** | `account.functionCall()` handles ed25519 signing + borsh serialisation internally. No custom crypto needed in the W3F. |
| **ERC-7683 intent schema** | W3F output is plug-and-play with ERC-7683 fillers today. NEAR Chain Signatures is the live execution layer. `IntentKind` enum routes rebalance vs settlement to different solver handlers. |

---

## 7 — W3F Deduplication (Storage-Based BatchMonitor)

The W3F uses Gelato's persistent `storage` API to prevent duplicate settlement
intents across cron cycles:

```
Per-cycle logic:

  storageKey = `batch_first_seen_${currentBatchId}`

  if storageKey not set:
    storage.set(storageKey, currentBlock)   ← first time we see this batch

  blocksElapsed = currentBlock − storage.get(storageKey)

  if blocksElapsed >= batchWindowBlocks AND pendingShares > 0:
    emit SETTLE_REDEMPTION_BATCH
    storage.delete(storageKey)              ← reset on settlement so next batch starts fresh
```

Key properties:
- **No duplicate settlement** — storage key is deleted after emission; new cycles skip the `>= window` check until a new batch is observed.
- **Batch rotation** — new `currentBatchId` → new `storageKey` → timer resets automatically.
- **Startup safe** — first cycle sets `firstSeenBlock = currentBlock` so the window starts from observation, not from genesis.

Default window: **300 blocks ≈ 1 hour** (mainnet 12 s/block).
Override: `batchWindowBlocks` userArg in Gelato dashboard.

---

## 8 — POC Boundaries (What Is NOT Implemented)

Explicitly out of scope:

1. **Real oracle** — `IOptionsPricer` is an interface only. No live Chainlink adapter deployed.
2. **Real perp venue adapter** — `MockPerpAdapter` only. No live Hyperliquid on-chain bindings.
3. **NEAR MPC signing** — W3F uses a plain ed25519 key. Production should use NEAR Chain Signatures for threshold MPC signing without key custody.
4. **Emergency shutdown / pause** — Thresholds are hardcoded constants. No governance.
5. **ozP secondary market peg** — No Curve/Balancer pool. Soft accounting peg only.
6. **Production batch accounting** — W3F approximates bridge amount as `totalPendingRedemption`. Production should read `batch.totalAssetsLocked` directly from the settled batch struct.

---

## 9 — Recommended Reading Order

For a new engineer:

1. **This file** — mental model first.
2. [`IPerpAdapter.sol`](../contracts/src/hedge/IPerpAdapter.sol) — the core perp abstraction.
3. [`BatchTypes.sol`](../contracts/src/core/BatchTypes.sol) — understand the exit data structures.
4. [`Vault.sol`](../contracts/src/core/Vault.sol) — entry point for all value flows + batch lifecycle.
5. [`Trancher.sol`](../contracts/src/core/Trancher.sol) — the split/merge math.
6. [`MockPerpAdapter.sol`](../contracts/src/hedge/MockPerpAdapter.sol) — how the POC simulates the perp venue.
7. [`w3f/src/index.ts`](../w3f/src/index.ts) — how the W3F decides when and what to emit.
8. [`test/unit/VaultBatch.unit.t.sol`](../contracts/test/unit/VaultBatch.unit.t.sol) — the complete async exit lifecycle in tests.
9. [`test/unit/VaultSecurity.unit.t.sol`](../contracts/test/unit/VaultSecurity.unit.t.sol) — the security model: allowance enforcement, emergency cancel, slippage guards.
10. [`test/integration/E2E.t.sol`](../contracts/test/integration/E2E.t.sol) — the full protocol flow end-to-end.
