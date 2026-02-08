// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IntentStore} from "./IntentStore.sol";
import {SwapIntent} from "./types/SwapIntent.sol";
import {SwapIntentLibrary} from "./libraries/SwapIntentLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title PrivacySwapExecutor
/// @notice Executes deferred swap intents. Enables timing + routing privacy.
/// @dev Pulls tokens from payer, swaps via PoolSwapTest, sends output to beneficiary.
///      Executor chooses which allowed pool to use (routing privacy).
contract PrivacySwapExecutor {
    using PoolIdLibrary for PoolKey;

    IntentStore public immutable intentStore;
    PoolSwapTest public immutable swapRouter;

    error IntentNotExecutable();
    error IntentAlreadyExecuted();
    error PoolNotAllowed();
    error TransferFailed();
    error ZeroOutput();
    error InsufficientOutput();
    error BatchIntentFailed(uint256 index);

    uint256 public batchId;

    event BatchExecuted(uint256 indexed batchId, uint256[] intentIds);

    constructor(IntentStore _intentStore, PoolSwapTest _swapRouter) {
        intentStore = _intentStore;
        swapRouter = _swapRouter;
    }

    /// @notice Execute a swap intent. Callable by anyone (permissionless execution).
    /// @param intentId ID from IntentStore
    /// @param key PoolKey for the pool to use (must be in intent's allowedPoolIds)
    /// @param sqrtPriceLimitX96 Price limit for slippage
    function executeIntent(
        uint256 intentId,
        PoolKey memory key,
        uint160 sqrtPriceLimitX96
    ) external {
        IntentStore.StoredIntent memory stored = intentStore.getIntent(intentId);
        if (stored.executed) revert IntentAlreadyExecuted();
        if (!intentStore.isExecutable(intentId)) revert IntentNotExecutable();

        SwapIntent memory intent = stored.intent;
        PoolId poolId = key.toId();
        // ROUTING PRIVACY: Must use deterministically selected pool (rule-bound execution)
        SwapIntentLibrary.requirePoolMatchesSelection(intent, poolId, block.number);
        SwapIntentLibrary.isExecutionAllowed(intent, block.number);

        // currency0=USDC, currency1=WETH; zeroForOne=false = sell WETH for USDC
        address weth = Currency.unwrap(key.currency1);
        address usdc = Currency.unwrap(key.currency0);

        // 1. Pull input tokens from payer
        IERC20Minimal(weth).transferFrom(stored.payer, address(this), stored.amountIn);

        // 2. Approve swap router
        IERC20Minimal(weth).approve(address(swapRouter), stored.amountIn);

        // 3. Execute swap (WETH -> USDC)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(stored.amountIn),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(intent)
        );

        // 4. Mark intent executed (we need to add this to IntentStore)
        // Store doesn't have markExecuted - we need to add it
        intentStore.markExecuted(intentId);

        // 5. Send USDC to beneficiary (revert if swap output is zero or below minOut)
        uint256 usdcBalance = IERC20Minimal(usdc).balanceOf(address(this));
        if (usdcBalance == 0) revert ZeroOutput();
        if (usdcBalance < intent.minAmountOut) revert InsufficientOutput();
        if (!IERC20Minimal(usdc).transfer(stored.beneficiary, usdcBalance)) revert TransferFailed();
    }

    /// @notice ROUTING PRIVACY: Returns the deterministically selected pool for execution.
    /// @dev Caller must pass the PoolKey matching this poolId to executeIntent.
    function getSelectedPoolForIntent(uint256 intentId, uint256 blockNumber) external view returns (PoolId) {
        IntentStore.StoredIntent memory stored = intentStore.getIntent(intentId);
        return SwapIntentLibrary.getSelectedPoolId(stored.intent, blockNumber);
    }

    /// @notice Execute multiple intents in one tx. Intent batching for attribution blurring.
    /// @dev All swaps go through PoolManager.swap via same hook. Atomic, same-block execution.
    ///      Each intent must use its deterministically selected pool (caller passes correct keys).
    ///      keys[i] must match getSelectedPoolForIntent(intentIds[i], block.number).
    ///      Uses params[i].sqrtPriceLimitX96 for slippage; amountSpecified/zeroForOne from intent.
    /// @param intentIds IDs from IntentStore
    /// @param keys PoolKey for each intent (key[i] must match getSelectedPoolId(intents[i], block.number))
    /// @param params SwapParams per intent; only sqrtPriceLimitX96 is used (amount comes from intent)
    function executeBatch(
        uint256[] calldata intentIds,
        PoolKey[] calldata keys,
        IPoolManager.SwapParams[] calldata params
    ) external {
        require(
            intentIds.length == keys.length && intentIds.length == params.length,
            "array length mismatch"
        );
        require(intentIds.length > 0 && intentIds.length <= 8, "1-8 intents"); // Bounded for gas

        for (uint256 i = 0; i < intentIds.length; i++) {
            try this.executeIntent(intentIds[i], keys[i], params[i].sqrtPriceLimitX96) {
                // success
            } catch {
                revert BatchIntentFailed(i);
            }
        }

        batchId++;
        emit BatchExecuted(batchId, intentIds);
    }
}
