// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwapIntent, SwapIntentConstants} from "../types/SwapIntent.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title SwapIntentLibrary
/// @notice Encoding, decoding, and validation for SwapIntent
library SwapIntentLibrary {
    error InvalidExecutionWindow();
    error InvalidMinDelay();
    error InvalidPoolCount();
    error PoolNotAllowed();
    error ExecutionWindowNotStarted();
    error ExecutionWindowExpired();
    error MinDelayNotMet();
    error EmptyHookData();

    /// @notice Decode SwapIntent from hookData
    /// @param hookData ABI-encoded SwapIntent from the swap caller
    function decode(bytes calldata hookData) internal pure returns (SwapIntent memory intent) {
        if (hookData.length == 0) revert EmptyHookData();
        return abi.decode(hookData, (SwapIntent));
    }

    /// @notice Validate SwapIntent structure and constraints
    function validate(SwapIntent memory intent) internal pure {
        if (intent.endBlock <= intent.startBlock) revert InvalidExecutionWindow();
        if (intent.endBlock - intent.startBlock < SwapIntentConstants.MIN_EXECUTION_WINDOW) {
            revert InvalidExecutionWindow();
        }
        if (intent.endBlock - intent.startBlock > SwapIntentConstants.MAX_EXECUTION_WINDOW) {
            revert InvalidExecutionWindow();
        }
        if (
            intent.minDelayBlocks < SwapIntentConstants.MIN_DELAY_BLOCKS
                || intent.minDelayBlocks > SwapIntentConstants.MAX_DELAY_BLOCKS
        ) revert InvalidMinDelay();
        if (intent.allowedPoolCount == 0 || intent.allowedPoolCount > SwapIntentConstants.MAX_ALLOWED_POOLS) {
            revert InvalidPoolCount();
        }
    }

    /// @notice Check if execution is allowed at current block given intent state
    /// @param intent The swap intent (may have createdAtBlock set from previous attempt)
    /// @param currentBlock block.number at execution time
    /// @return valid True if swap can proceed
    function isExecutionAllowed(SwapIntent memory intent, uint256 currentBlock)
        internal
        pure
        returns (bool valid)
    {
        // Within execution window
        if (currentBlock < intent.startBlock) revert ExecutionWindowNotStarted();
        if (currentBlock > intent.endBlock) revert ExecutionWindowExpired();

        // Min delay: if createdAtBlock not set, treat current block as creation (first valid attempt)
        uint32 creationBlock = intent.createdAtBlock;
        if (creationBlock == 0) {
            // First execution attempt - allowed if we're past startBlock
            // Min delay is satisfied by the fact we're in window (startBlock is in future from user's perspective)
            return true;
        }
        if (currentBlock - creationBlock < intent.minDelayBlocks) revert MinDelayNotMet();
        return true;
    }

    /// @notice Check if poolId is in the allowed set
    function isPoolAllowed(SwapIntent memory intent, PoolId poolId) internal pure returns (bool) {
        for (uint256 i = 0; i < intent.allowedPoolCount; i++) {
            if (PoolId.unwrap(intent.allowedPoolIds[i]) == PoolId.unwrap(poolId)) return true;
        }
        return false;
    }

    /// @notice ROUTING ENTROPY: Deterministic pool selection. Unpredictable at submission time.
    /// @dev Selection = hash(blockhash(blockNumber-1), intentHash) % poolCount.
    ///      - blockhash(blockNumber-1): only known once block is mined; executor cannot precompute.
    ///      - intentHash: binds selection to specific intent; different intents in same block
    ///        canRoute to different pools (observable routing entropy).
    ///      - Executor CANNOT bias: hook validates beforeSwap; wrong pool → revert.
    ///      - Verifiable after execution: onchain data reproduces selection.
    /// @param intent The swap intent (allowedPoolIds, allowedPoolCount)
    /// @param blockNumber Current block (use block.number at execution time)
    /// @return selectedPoolId The pool that MUST be used for this swap
    function getSelectedPoolId(SwapIntent memory intent, uint256 blockNumber) internal view returns (PoolId selectedPoolId) {
        if (intent.allowedPoolCount == 0) return PoolId.wrap(bytes32(0));
        if (intent.allowedPoolCount == 1) return intent.allowedPoolIds[0];

        bytes32 bh = blockhash(blockNumber > 0 ? blockNumber - 1 : 0);
        bytes32 intentHash = keccak256(abi.encode(intent));
        uint256 index = uint256(keccak256(abi.encode(bh, intentHash))) % intent.allowedPoolCount;
        return intent.allowedPoolIds[index];
    }

    /// @notice ROUTING PRIVACY: Validate that the swap uses the deterministically selected pool.
    /// @dev Reverts if executor tried to use a different pool (e.g. to extract value).
    function requirePoolMatchesSelection(SwapIntent memory intent, PoolId actualPoolId, uint256 blockNumber)
        internal
        view
    {
        PoolId expected = getSelectedPoolId(intent, blockNumber);
        if (PoolId.unwrap(actualPoolId) != PoolId.unwrap(expected)) revert PoolNotAllowed();
    }

    /// @notice Encode intent for storage/callback (includes updated createdAtBlock)
    function encode(SwapIntent memory intent) internal pure returns (bytes memory) {
        return abi.encode(intent);
    }
}
