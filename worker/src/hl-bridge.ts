/**
 * Hyperliquid Bridge2 deposit helper.
 *
 * Bridge2 deposit = simple ERC-20 USDC transfer to the contract address.
 * Hyperliquid validators detect the transfer and credit the sender's account.
 *
 * Architecture:
 *   The keeper holds its own USDC on Arbitrum for HL margin.
 *   No wstETH→USDC swap needed — avoids sandwich attacks.
 *   At 25x leverage, a $100k vault only needs ~$4k USDC margin on HL.
 *
 * Bridge2: 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7 (Arbitrum One)
 * USDC:    0xaf88d065e77c8cC2239327C5EDb3A432268e5831 (Arbitrum One)
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

/// Hyperliquid Bridge2 on Arbitrum — just send USDC here
export const HL_BRIDGE2_ADDRESS: Address =
  "0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7";

/// Native USDC on Arbitrum (NOT USDC.e)
export const USDC_ARBITRUM_ADDRESS: Address =
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
    name: "transfer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
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
                    DEPOSIT TO HYPERLIQUID
/////////////////////////////////////////////////////////////// */

/**
 * Deposit USDC to Hyperliquid via Bridge2.
 *
 * The mechanism is a simple ERC-20 transfer — no special function call.
 * HL validators watch for incoming USDC transfers and credit the sender.
 *
 * @param config Bridge configuration
 * @param amountUsdc Amount in USDC (human-readable, e.g. "100.00")
 */
export async function depositToHyperliquid(
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
    // Check balance
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

    // Transfer USDC to Bridge2 — that's it
    console.log(
      `[hl-bridge] Depositing ${amountUsdc} USDC to Hyperliquid Bridge2...`
    );

    const txHash = await walletClient.writeContract({
      address: USDC_ARBITRUM_ADDRESS,
      abi: ERC20_ABI,
      functionName: "transfer",
      args: [HL_BRIDGE2_ADDRESS, amountRaw],
    });

    await publicClient.waitForTransactionReceipt({ hash: txHash });

    console.log(`[hl-bridge] Deposit complete: ${txHash}`);

    return {
      success: true,
      txHash,
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
