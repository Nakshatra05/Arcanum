// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title SwapIntent
/// @notice Data structure for intent-based swap execution with privacy properties.
/// @dev Encoded in hookData and passed to PoolManager.swap(). All validation is onchain.
struct SwapIntent {
    /// @notice Execution window: swap allowed only when block.number in [startBlock, endBlock]
    /// @dev Prevents deterministic execution timing - user cannot predict exact block
    uint64 startBlock;
    uint64 endBlock;

    /// @notice Minimum blocks that must pass since intent creation before execution allowed
    /// @dev Timing privacy: prevents immediate execution, creates uncertainty for MEV bots
    uint32 minDelayBlocks;

    /// @notice Block when intent was created (submitted). Set by hook from block.number at first valid execution attempt
    /// @dev Used to enforce minDelayBlocks. Zero means not yet recorded.
    uint32 createdAtBlock;

    /// @notice Allowed pool IDs for this swap. Swap must use one of these pools.
    /// @dev Routing privacy: user specifies multiple valid paths, executor chooses
    /// @dev Max 4 pools to bound gas and prevent DoS
    PoolId[4] allowedPoolIds;
    uint8 allowedPoolCount;

    /// @notice Minimum output amount (slippage protection). Exact meaning depends on swap direction.
    /// @dev For zeroForOne exactIn: min amount1. For zeroForOne exactOut: not used. Etc.
    uint256 minAmountOut;

    /// @notice Optional salt for intent uniqueness (e.g. for replay protection)
    bytes32 salt;
}

/// @notice Constants for SwapIntent validation
library SwapIntentConstants {
    uint32 constant MIN_EXECUTION_WINDOW = 2; // At least 2 blocks wide
    uint32 constant MAX_EXECUTION_WINDOW = 256; // ~1 hour at 14s/block
    uint32 constant MIN_DELAY_BLOCKS = 0; // 0 = same-block submit+execute in one script
    uint32 constant MAX_DELAY_BLOCKS = 100;
    uint8 constant MAX_ALLOWED_POOLS = 4;
}
