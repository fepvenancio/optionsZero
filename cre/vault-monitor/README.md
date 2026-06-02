# vault-monitor

Chainlink CRE workflow that monitors the OptionZero Vault on Sepolia.

## Triggers

| Trigger | Condition | Intent |
|---|---|---|
| Size imbalance | `|TVL − perpNotional| / TVL > 1%` | `RESIZE_SHORT_PERP` |
| Pending batch | `totalPendingRedemption > 0` | `SETTLE_REDEMPTION_BATCH` |

## Simulate

```bash
cre workflow simulate vault-monitor --target staging-settings
```

## Deploy

```bash
cre account access          # request deployment access
cre workflow deploy vault-monitor --target staging-settings
```
