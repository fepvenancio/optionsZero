/// ABIs for on-chain reads — only the view functions the monitor needs.

export const vaultAbi = [
  {
    inputs: [],
    name: "totalAssets",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "totalDepositedAssets",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "totalPendingRedemption",
    outputs: [{ internalType: "uint128", name: "", type: "uint128" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "currentBatchId",
    outputs: [{ internalType: "bytes32", name: "", type: "bytes32" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [{ internalType: "bytes32", name: "batchId", type: "bytes32" }],
    name: "getBatch",
    outputs: [
      {
        components: [
          { internalType: "bool", name: "isClosed", type: "bool" },
          { internalType: "bool", name: "isSettled", type: "bool" },
          { internalType: "uint64", name: "openedAtBlock", type: "uint64" },
          { internalType: "uint128", name: "totalSharesQueued", type: "uint128" },
          { internalType: "uint128", name: "totalAssetsLocked", type: "uint128" },
          { internalType: "uint128", name: "assetsReturned", type: "uint128" },
          { internalType: "uint128", name: "claimedAssets", type: "uint128" },
        ],
        internalType: "struct BatchTypes.BatchInfo",
        name: "",
        type: "tuple",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "asset",
    outputs: [{ internalType: "address", name: "", type: "address" }],
    stateMutability: "view",
    type: "function",
  },
] as const;

export const adapterAbi = [
  {
    inputs: [],
    name: "totalHedgedNotional",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "accruedFunding",
    outputs: [{ internalType: "int256", name: "", type: "int256" }],
    stateMutability: "view",
    type: "function",
  },
] as const;

/* ///////////////////////////////////////////////////////////////
                     WRITE ABIS (EXECUTOR)
/////////////////////////////////////////////////////////////// */

export const vaultWriteAbi = [
  {
    inputs: [],
    name: "closeBatch",
    outputs: [
      { internalType: "bytes32", name: "closedBatchId", type: "bytes32" },
      { internalType: "bytes32", name: "newBatchId", type: "bytes32" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "bytes32", name: "batchId", type: "bytes32" },
      { internalType: "uint128", name: "assetsReturned", type: "uint128" },
    ],
    name: "settleBatch",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;

export const adapterWriteAbi = [
  {
    inputs: [
      { internalType: "uint256", name: "notionalWstETH", type: "uint256" },
    ],
    name: "openPosition",
    outputs: [
      { internalType: "bytes32", name: "positionId", type: "bytes32" },
    ],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "bytes32", name: "positionId", type: "bytes32" },
      { internalType: "uint256", name: "newNotionalWstETH", type: "uint256" },
    ],
    name: "resizePosition",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [],
    name: "settleFunding",
    outputs: [{ internalType: "int256", name: "settled", type: "int256" }],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
