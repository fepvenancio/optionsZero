// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {MockPerpAdapter} from "../src/hedge/MockPerpAdapter.sol";
import {PToken} from "../src/tokens/PToken.sol";
import {NToken} from "../src/tokens/NToken.sol";
import {Trancher} from "../src/core/Trancher.sol";
import {Vault} from "../src/core/Vault.sol";
import {YieldAccumulator} from "../src/core/YieldAccumulator.sol";
import {IntentEncoder} from "../src/intents/IntentEncoder.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/* ///////////////////////////////////////////////////////////////
                     INLINE MOCKS (Anvil only)
/////////////////////////////////////////////////////////////// */

/// @dev Minimal ERC-20 wstETH stand-in for local Anvil testing.
///      NOT deployed when WSTETH_ADDRESS env var is set (mainnet fork mode).
contract MockWstETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped stETH";
    }

    function symbol() public pure override returns (string memory) {
        return "wstETH";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fixed-price oracle: 1 wstETH = $3,000. Used only by YieldAccumulator.
///      Trancher coverage is oracle-free in the Perp model (wstETH/wstETH).
contract MockPricer {
    uint256 public constant USD_PER_WSTETH = 3_000e18;

    function getEthUsdPrice() external pure returns (uint256) {
        return 3_000e8;
    }

    function getWstETHRate() external pure returns (uint256) {
        return 1e18;
    }

    function wstETHToUSD(uint256 wstETHAmount) external pure returns (uint256) {
        return (wstETHAmount * USD_PER_WSTETH) / 1e18;
    }
}

/* ///////////////////////////////////////////////////////////////
                       DEPLOYMENT SCRIPT
/////////////////////////////////////////////////////////////// */

/// @title  Deploy
/// @notice Full OptionZero POC deployment for a blank Anvil node.
///
/// @dev    Perp model deployment order (nonce-ordered, respects constructor deps):
///
///           nonce+0  MockWstETH       — underlying ERC-20 (Anvil only)
///           nonce+1  MockPricer       — fixed $3,000 oracle (for YieldAccumulator)
///           nonce+2  MockPerpAdapter  — 1x short perp simulator (constant delta -1.0)
///           nonce+3  PToken(trancher) — pre-computed trancher address
///           nonce+4  NToken(trancher) — pre-computed trancher address
///           nonce+5  Trancher(vault, pToken, nToken, perpAdapter, pricer)
///           nonce+6  Vault(wstETH, trancher, perpAdapter)
///           nonce+7  YieldAccumulator(vault, pricer, perpAdapter)
///           nonce+8  IntentEncoder    — stateless
///
///         Both `trancherAddr` and `vaultAddr` are pre-computed via
///         Foundry's `computeCreateAddress` before any deployment, then
///         passed into the constructors. This eliminates the address(0) bug.
///
/// Usage (blank Anvil):
///   anvil &
///   forge script script/Deploy.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// Usage (mainnet fork):
///   WSTETH_ADDRESS=0x7f39... forge script script/Deploy.s.sol \
///     --rpc-url $FORK_URL --fork-block-number <N> --broadcast
contract Deploy is Script {
    function run() external {
        // Determine deployer and signer:
        //
        //   PRIVATE_KEY env set  → explicit key (CI/CD, Anvil --private-key via env)
        //   PRIVATE_KEY not set  → vm.startBroadcast() with no args, which respects:
        //                          --private-key <key>   (Anvil local)
        //                          --account <name>      (cast keystore / hardware)
        //                          --ledger              (Ledger hardware wallet)
        //
        //   --sender <addr>  sets msg.sender during simulation so nonce pre-compute
        //   uses the correct deployer address even before broadcast starts.

        uint256 explicitKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = explicitKey != 0 ? vm.addr(explicitKey) : msg.sender;

        // Detect Anvil mode: if no WSTETH_ADDRESS, deploy a mock.
        bool anvilMode = vm.envOr("WSTETH_ADDRESS", address(0)) == address(0);

        if (explicitKey != 0) {
            vm.startBroadcast(explicitKey);
        } else {
            vm.startBroadcast(); // signing delegated to --account / --ledger / --private-key
        }

        uint64 nonce = vm.getNonce(deployer);

        // Deployment order (Anvil mode) — nonce consumed by every broadcast tx:
        //   nonce+0  MockWstETH
        //   nonce+1  MockPricer
        //   nonce+2  MockWstETH.mint(account[0])   \
        //   nonce+3  MockWstETH.mint(account[1])    } 3 broadcast txs
        //   nonce+4  MockWstETH.mint(account[2])   /
        //   nonce+5  MockPerpAdapter
        //   nonce+6  PToken       ← needs trancherAddr in constructor
        //   nonce+7  NToken       ← needs trancherAddr in constructor
        //   nonce+8  Trancher    ← needs vaultAddr in constructor
        //   nonce+9  Vault
        //   nonce+10 YieldAccumulator
        //   nonce+11 IntentEncoder
        //
        // Fork mode skips MockWstETH, MockPricer, and the 3 mints (-5 nonces).

        uint64 trancherNonce = anvilMode ? nonce + 8 : nonce + 3;
        uint64 vaultNonce = anvilMode ? nonce + 9 : nonce + 4;

        address trancherAddr = vm.computeCreateAddress(deployer, trancherNonce);
        address vaultAddr = vm.computeCreateAddress(deployer, vaultNonce);

        // -- Deploy infrastructure -----------------------------------------------

        address wstETH;
        address pricerAddr;

        if (anvilMode) {
            MockWstETH mockWst = new MockWstETH(); // nonce + 0
            wstETH = address(mockWst);

            MockPricer mockPricer = new MockPricer(); // nonce + 1
            pricerAddr = address(mockPricer);

            // Mint 1000 wstETH to the first 3 Anvil test accounts.
            address[3] memory testAccounts = [
                0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // account[0]
                0x70997970C51812dc3A010C7d01b50e0d17dc79C8, // account[1]
                0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC // account[2]
            ];
            for (uint256 i; i < 3; ++i) {
                MockWstETH(wstETH).mint(testAccounts[i], 1_000e18);
            }
            // Also mint to the actual deployer (needed when running against Sepolia
            // where the deployer is not one of the Anvil test accounts above).
            MockWstETH(wstETH).mint(deployer, 1_000e18);
        } else {
            wstETH = vm.envAddress("WSTETH_ADDRESS");
            pricerAddr = vm.envOr("PRICER_ADDRESS", address(0));
        }

        // Perp adapter: constant delta -1.0, variable funding rate.
        MockPerpAdapter adapter = new MockPerpAdapter(); // nonce+2 (anvil) / nonce+0 (fork)

        // -- Deploy P/N tokens with pre-computed trancher address ----------------
        PToken pToken = new PToken(trancherAddr); // tokenBase + 0
        NToken nToken = new NToken(trancherAddr); // tokenBase + 1

        // -- Deploy Trancher ----------------------------------------------------
        Trancher trancher = new Trancher( // tokenBase + 2
            vaultAddr,
            address(pToken),
            address(nToken),
            address(adapter),
            pricerAddr
        );
        require(address(trancher) == trancherAddr, "Deploy: trancher addr mismatch");

        // -- Deploy Vault -------------------------------------------------------
        Vault vault = new Vault( // tokenBase + 3
            wstETH,
            address(trancher),
            address(adapter)
        );
        require(address(vault) == vaultAddr, "Deploy: vault addr mismatch");

        // -- Deploy YieldAccumulator --------------------------------------------
        YieldAccumulator yieldAccum = new YieldAccumulator(address(vault), pricerAddr, address(adapter));

        // -- Deploy IntentEncoder (stateless) ------------------------------------
        IntentEncoder encoder = new IntentEncoder();

        vm.stopBroadcast();

        // -- Output: KEY=value pairs for shell sourcing -------------------------
        console.log("# OptionZero Perp Deployment -- source this output to configure the daemon");
        console.log("# Generated at block:", block.number);
        console.log("");
        console.log("WSTETH_ADDRESS=%s", wstETH);
        console.log("VAULT_ADDRESS=%s", address(vault));
        console.log("TRANCHER_ADDRESS=%s", address(trancher));
        console.log("ADAPTER_ADDRESS=%s", address(adapter));
        console.log("PTOKEN_ADDRESS=%s", address(pToken));
        console.log("NTOKEN_ADDRESS=%s", address(nToken));
        console.log("YIELD_ACCUM_ADDRESS=%s", address(yieldAccum));
        console.log("ENCODER_ADDRESS=%s", address(encoder));
        console.log("");
        // ABI selectors for the daemon's eth_call reads.
        console.log("# ABI selectors (4-byte, for daemon eth_call reads)");
        console.logBytes4(MockPerpAdapter.totalHedgedNotional.selector);
        console.logBytes4(MockPerpAdapter.accruedFunding.selector);
        console.logBytes4(Vault.totalAssets.selector);
    }
}
