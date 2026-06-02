// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockPerpAdapter} from "../src/hedge/MockPerpAdapter.sol";
import {Vault} from "../src/core/Vault.sol";

/// @title  Simulate
/// @notice Three-phase on-chain state driver for the E2E live simulation.
///
///         Adapted for the Perp model. Driven by the `PHASE` environment variable:
///           PHASE=1  Seed    -- Alice deposits 50 wstETH into the vault.
///           PHASE=2  Hedge   -- Open a perp position at exactly 100% TVL coverage.
///                    sizeDelta = 0 -> daemon stays quiet (perfectly balanced).
///           PHASE=3  Imbalance -- Alice deposits 50 more wstETH, perp NOT resized.
///                    sizeDelta = 50e18 >> 1% threshold -> daemon fires intent.
///
/// Usage (after sourcing deploy output):
///   PHASE=1 forge script script/Simulate.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key $ANVIL_KEY
///
///   PHASE=2 forge script script/Simulate.s.sol ...
///   PHASE=3 forge script script/Simulate.s.sol ...
contract Simulate is Script {
    function run() external {
        uint256 deployerKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerKey);

        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address adapterAddr = vm.envAddress("ADAPTER_ADDRESS");
        address wstETH = vm.envAddress("WSTETH_ADDRESS");

        uint256 phase = vm.envOr("PHASE", uint256(1));

        Vault vault = Vault(vaultAddr);
        MockPerpAdapter adapter = MockPerpAdapter(adapterAddr);

        vm.startBroadcast(deployerKey);

        if (phase == 1) {
            // -- Phase 1: Genesis deposit ------------------------------------------
            // Alice (= deployer on Anvil) deposits 50 wstETH.
            // split() fires with totalDepositedAssets() == 0 -> genesis bootstrap
            // -> 100% P tokens, 0 N tokens.
            console.log("[Phase 1] Depositing 50 wstETH into vault...");

            // Approve vault to pull wstETH.
            (bool ok,) = wstETH.call(abi.encodeWithSignature("approve(address,uint256)", vaultAddr, 50e18));
            require(ok, "Simulate: wstETH approve failed");

            uint256 shares = vault.deposit(50e18, deployer);

            console.log("[Phase 1] Vault shares received:", shares);
            console.log("[Phase 1] totalAssets() =", vault.totalAssets());
            console.log("[Phase 1] totalDepositedAssets() =", vault.totalDepositedAssets());
            console.log("[Phase 1] DONE -- daemon should stay quiet (no perp yet -> no imbalance check)");
        } else if (phase == 2) {
            // -- Phase 2: Open perp hedge at 100% coverage -------------------------
            // TVL = 50 wstETH. Open perp at exactly 50 wstETH notional.
            // imbalance = |50 - 50| = 0 -> daemon stays quiet.
            console.log("[Phase 2] Opening perp at 100% coverage (50 wstETH notional)...");

            uint256 tvl = vault.totalDepositedAssets();
            bytes32 posId = adapter.openPosition(tvl); // match TVL exactly

            console.log("[Phase 2] Position opened. positionId:");
            console.logBytes32(posId);
            console.log("[Phase 2] totalHedgedNotional =", adapter.totalHedgedNotional());
            console.log("[Phase 2] TVL =", tvl);
            console.log("[Phase 2] DONE -- daemon stays quiet (imbalance = 0)");
        } else if (phase == 3) {
            // -- Phase 3: TVL grows, perp NOT resized -> imbalance fires -----------
            // Alice deposits another 50 wstETH -> TVL = 100 wstETH.
            // perpNotional is still 50 wstETH -> imbalance = 50 wstETH = 50% >> 1%.
            // sizeDelta = +50e18 -> daemon emits IntentRequested + prints resize JSON.
            console.log("[Phase 3] Depositing 50 more wstETH (perp will NOT be resized)...");

            (bool ok,) = wstETH.call(abi.encodeWithSignature("approve(address,uint256)", vaultAddr, 50e18));
            require(ok, "Simulate: wstETH approve failed");
            vault.deposit(50e18, deployer);

            uint256 deposited = vault.totalDepositedAssets();
            uint256 notional = adapter.totalHedgedNotional();

            console.log("[Phase 3] totalDepositedAssets =", deposited);
            console.log("[Phase 3] perpNotional         =", notional);
            console.log("[Phase 3] DONE -- calling checkAndEmitIntent()...");

            // Trigger the on-chain intent emission.
            vault.checkAndEmitIntent();
            console.log("[Phase 3] IntentRequested emitted -- daemon prints resize JSON");
        } else {
            revert("Simulate: invalid PHASE (must be 1, 2, or 3)");
        }

        vm.stopBroadcast();
    }
}
