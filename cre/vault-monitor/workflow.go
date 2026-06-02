//go:build wasip1

package main

import (
	"fmt"
	"log/slog"
	"math/big"

	"cre/contracts/evm/src/generated/adapter"
	"cre/contracts/evm/src/generated/vault"

	"github.com/ethereum/go-ethereum/common"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
)

/* ///////////////////////////////////////////////////////////////
                         CONFIGURATION
/////////////////////////////////////////////////////////////// */

// EvmConfig holds addresses for a single chain deployment.
type EvmConfig struct {
	VaultAddress   string `json:"vaultAddress"`
	AdapterAddress string `json:"adapterAddress"`
	ChainName      string `json:"chainName"`
}

// Config is loaded from config.staging.json / config.production.json.
type Config struct {
	Schedule             string      `json:"schedule"`
	ImbalanceThresholdBps int64      `json:"imbalanceThresholdBps"`
	Evms                 []EvmConfig `json:"evms"`
}

/* ///////////////////////////////////////////////////////////////
                        EXECUTION RESULT
/////////////////////////////////////////////////////////////// */

// MonitorResult is the structured output of each cron cycle.
type MonitorResult struct {
	TotalAssetsWei   string `json:"totalAssetsWei"`
	HedgedNotionalWei string `json:"hedgedNotionalWei"`
	ImbalanceBps     int64  `json:"imbalanceBps"`
	PendingShares    string `json:"pendingSharesWei"`
	IntentFired      string `json:"intentFired"`
}

/* ///////////////////////////////////////////////////////////////
                           WORKFLOW
/////////////////////////////////////////////////////////////// */

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	cronTrigger := cron.Trigger(&cron.Config{Schedule: config.Schedule})

	return cre.Workflow[*Config]{
		cre.Handler(cronTrigger, onCronTrigger),
	}, nil
}

func onCronTrigger(config *Config, runtime cre.Runtime, trigger *cron.Payload) (*MonitorResult, error) {
	logger := runtime.Logger()
	scheduledTime := trigger.ScheduledExecutionTime.AsTime()
	logger.Info("Vault monitor cycle started", "scheduledTime", scheduledTime)

	if len(config.Evms) == 0 {
		return nil, fmt.Errorf("no EVM configuration provided")
	}
	evmCfg := config.Evms[0]

	// ── Resolve chain selector ───────────────────────────────────────────
	chainSelector, err := evm.ChainSelectorFromName(evmCfg.ChainName)
	if err != nil {
		return nil, fmt.Errorf("invalid chain name %q: %w", evmCfg.ChainName, err)
	}
	evmClient := &evm.Client{ChainSelector: chainSelector}

	// ── Create contract bindings ─────────────────────────────────────────
	vaultAddr := common.HexToAddress(evmCfg.VaultAddress)
	adapterAddr := common.HexToAddress(evmCfg.AdapterAddress)

	vaultContract, err := vault.NewVault(evmClient, vaultAddr, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create Vault binding: %w", err)
	}

	adapterContract, err := adapter.NewAdapter(evmClient, adapterAddr, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create Adapter binding: %w", err)
	}

	// ── Read on-chain state (finalized block = -3) ───────────────────────
	// Fire both reads as promises, then await them for parallel execution
	totalAssetsPromise := vaultContract.TotalAssets(runtime, big.NewInt(-3))
	hedgedNotionalPromise := adapterContract.TotalHedgedNotional(runtime, big.NewInt(-3))
	pendingRedemptionPromise := vaultContract.TotalPendingRedemption(runtime, big.NewInt(-3))

	totalAssets, err := totalAssetsPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to read totalAssets: %w", err)
	}

	hedgedNotional, err := hedgedNotionalPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to read totalHedgedNotional: %w", err)
	}

	pendingRedemption, err := pendingRedemptionPromise.Await()
	if err != nil {
		return nil, fmt.Errorf("failed to read totalPendingRedemption: %w", err)
	}

	logger.Info("On-chain state read",
		"totalAssets", totalAssets.String(),
		"hedgedNotional", hedgedNotional.String(),
		"pendingRedemption", pendingRedemption.String(),
	)

	// ── Trigger 1: Size Imbalance ────────────────────────────────────────
	intentFired := "NONE"

	if totalAssets.Sign() > 0 {
		var absDelta big.Int
		delta := new(big.Int).Sub(totalAssets, hedgedNotional)
		absDelta.Abs(delta)

		// imbalanceBps = |delta| * 10000 / totalAssets
		imbalanceBps := new(big.Int).Mul(&absDelta, big.NewInt(10000))
		imbalanceBps.Div(imbalanceBps, totalAssets)

		threshold := big.NewInt(config.ImbalanceThresholdBps)

		if imbalanceBps.Cmp(threshold) > 0 {
			direction := "INCREASE_SHORT"
			if delta.Sign() < 0 {
				direction = "DECREASE_SHORT"
			}

			logger.Info("INTENT: RESIZE_SHORT_PERP",
				"imbalanceBps", imbalanceBps.String(),
				"sizeDeltaWei", delta.String(),
				"direction", direction,
			)
			intentFired = fmt.Sprintf("RESIZE_SHORT_PERP direction=%s imbalance=%sbps delta=%s",
				direction, imbalanceBps.String(), delta.String())
		}
	}

	// ── Trigger 2: Pending Batch ─────────────────────────────────────────
	if pendingRedemption.Sign() > 0 {
		logger.Info("INTENT: SETTLE_REDEMPTION_BATCH",
			"pendingShares", pendingRedemption.String(),
		)
		if intentFired == "NONE" {
			intentFired = fmt.Sprintf("SETTLE_REDEMPTION_BATCH pending=%s", pendingRedemption.String())
		} else {
			intentFired += fmt.Sprintf(" | SETTLE_REDEMPTION_BATCH pending=%s", pendingRedemption.String())
		}
	}

	// ── Log summary ──────────────────────────────────────────────────────
	var imbalanceBpsVal int64
	if totalAssets.Sign() > 0 {
		absDelta := new(big.Int).Abs(new(big.Int).Sub(totalAssets, hedgedNotional))
		bps := new(big.Int).Mul(absDelta, big.NewInt(10000))
		bps.Div(bps, totalAssets)
		imbalanceBpsVal = bps.Int64()
	}

	logger.Info("Vault monitor cycle complete",
		"intentFired", intentFired,
		"imbalanceBps", imbalanceBpsVal,
	)

	return &MonitorResult{
		TotalAssetsWei:    totalAssets.String(),
		HedgedNotionalWei: hedgedNotional.String(),
		ImbalanceBps:      imbalanceBpsVal,
		PendingShares:     pendingRedemption.String(),
		IntentFired:       intentFired,
	}, nil
}
