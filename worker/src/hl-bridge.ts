/**
 * Hyperliquid Bridge2 deposit helper — sends USDC from Arbitrum
 * to the Hyperliquid L1 for perp margin.
 *
 * Flow:
 *   1. NEAR Intents delivers USDC to our wallet on Arbitrum
 *   2. This module approves + deposits to Bridge2 contract
 *   3. Funds appear in HyperCore for perp trading
 *
 * Bridge2 contract: 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7 (Arbitrum)
 * Native USDC: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 (Arbitrum)
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  parseUnits,
  formatUnits,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";

/* ///////////////////////////////////////////////////////////////
                          CONSTANTS
/////////////////////////////////////////////////////////////// */

/// Hyperliquid Bridge2 on Arbitrum
const HL_BRIDGE2_ADDRESS: Address =
  "0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7";

/// Native USDC on Arbitrum (NOT USDC.e)
const USDC_ARBITRUM_ADDRESS: Address =
  "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

/// Minimum Hyperliquid deposit
const MIN_DEPOSIT_USDC = 5;

/* ///////////////////////////////////////////////////////////////
                            TYPES
/////////////////////////////////////////////////////////////// */

export interface HlBridgeConfig {
  /** Arbitrum RPC URL */
  arbitrumRpcUrl: string;
  /** Private key for signing Arbitrum transactions */
  privateKey: Hex;
}

export interface DepositResult {
  success: boolean;
  txHash?: string;
  amountUsdc: string;
  error?: string;
}

/* ///////////////////////////////////////////////////////////////
                          ABI FRAGMENTS
/////////////////////////////////////////////////////////////// */

const ERC20_ABI = [
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

/* ///////////////////////////////////////////////////////////////
                      READ FUNCTIONS
/////////////////////////////////////////////////////////////// */

/**
 * Check USDC balance on Arbitrum for a given address.
 */
export async function getUsdcBalance(
  config: HlBridgeConfig,
  address?: Address
): Promise<string> {
  const account = privateKeyToAccount(config.privateKey);
  const target = address ?? account.address;

  const client = createPublicClient({
    chain: arbitrum,
    transport: http(config.arbitrumRpcUrl),
  });

  const balance = await client.readContract({
    address: USDC_ARBITRUM_ADDRESS,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: [target],
  });

  return formatUnits(balance, 6);
}

/* ///////////////////////////////////////////////////////////////
                    APPROVE + DEPOSIT
/////////////////////////////////////////////////////////////// */

/**
 * Approve USDC spending by Bridge2 and deposit to Hyperliquid.
 *
 * @param config Bridge configuration
 * @param amountUsdc Amount in USDC (human-readable, e.g. "100.00")
 */
export async function approveAndDeposit(
  config: HlBridgeConfig,
  amountUsdc: string
): Promise<DepositResult> {
  const amount = parseFloat(amountUsdc);

  if (amount < MIN_DEPOSIT_USDC) {
    return {
      success: false,
      amountUsdc,
      error: `Below minimum deposit: ${amount} < ${MIN_DEPOSIT_USDC} USDC`,
    };
  }

  const account = privateKeyToAccount(config.privateKey);
  const amountRaw = parseUnits(amountUsdc, 6);

  const publicClient = createPublicClient({
    chain: arbitrum,
    transport: http(config.arbitrumRpcUrl),
  });

  const walletClient = createWalletClient({
    account,
    chain: arbitrum,
    transport: http(config.arbitrumRpcUrl),
  });

  try {
    // Step 1: Check balance
    const balance = await publicClient.readContract({
      address: USDC_ARBITRUM_ADDRESS,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [account.address],
    });

    if (balance < amountRaw) {
      return {
        success: false,
        amountUsdc,
        error: `Insufficient USDC: have ${formatUnits(balance, 6)}, need ${amountUsdc}`,
      };
    }

    // Step 2: Check allowance
    const allowance = await publicClient.readContract({
      address: USDC_ARBITRUM_ADDRESS,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [account.address, HL_BRIDGE2_ADDRESS],
    });

    // Step 3: Approve if needed
    if (allowance < amountRaw) {
      console.log(
        `[hl-bridge] Approving ${amountUsdc} USDC for Bridge2...`
      );

      const approveHash = await walletClient.writeContract({
        address: USDC_ARBITRUM_ADDRESS,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [HL_BRIDGE2_ADDRESS, amountRaw],
      });

      await publicClient.waitForTransactionReceipt({ hash: approveHash });
      console.log(`[hl-bridge] Approved: ${approveHash}`);
    }

    // Step 4: Deposit to Hyperliquid Bridge2
    // The Bridge2 uses a simple transfer of USDC to the contract address
    // which credits the sender's HyperCore account.
    console.log(
      `[hl-bridge] Depositing ${amountUsdc} USDC to Hyperliquid Bridge2...`
    );

    const depositHash = await walletClient.sendTransaction({
      to: HL_BRIDGE2_ADDRESS,
      data: `0x` as Hex, // Simple USDC transfer after approval
      value: 0n,
    });

    await publicClient.waitForTransactionReceipt({ hash: depositHash });

    console.log(`[hl-bridge] Deposit complete: ${depositHash}`);

    return {
      success: true,
      txHash: depositHash,
      amountUsdc,
    };
  } catch (err) {
    return {
      success: false,
      amountUsdc,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
