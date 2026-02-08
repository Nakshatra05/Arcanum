// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

/// @notice Helper to add liquidity in one tx. Pulls tokens from user, transfers to modify router, adds to pool.
/// @dev Use same (tickLower, tickUpper, salt) as initial deployment to add to existing position.
contract AddLiquidityHelper {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    PoolModifyLiquidityTest public immutable modifyRouter;
    address public immutable currency0;
    address public immutable currency1;

    int24 public constant TICK_LOWER = -120;
    int24 public constant TICK_UPPER = 120;

    constructor(
        IPoolManager _poolManager,
        address _modifyRouter,
        address _currency0,
        address _currency1
    ) {
        poolManager = _poolManager;
        modifyRouter = PoolModifyLiquidityTest(_modifyRouter);
        currency0 = _currency0;
        currency1 = _currency1;
    }

    /// @notice Add liquidity in one tx. Caller must have approved this contract for amount0 and amount1.
    function addLiquidity(PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        require(key.currency0 == Currency.wrap(currency0) && key.currency1 == Currency.wrap(currency1), "Wrong pool");

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint160 sqrtPriceALower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtPriceBUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceALower, sqrtPriceBUpper, amount0, amount1
        );
        require(liquidity > 0, "Zero liquidity");

        IERC20Minimal(currency0).transferFrom(msg.sender, address(modifyRouter), amount0);
        IERC20Minimal(currency1).transferFrom(msg.sender, address(modifyRouter), amount1);

        modifyRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
    }
}
