// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IntentStore} from "../src/IntentStore.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";

/// @notice Integration test: full flow - init pool, add liquidity, swap with SwapIntent
contract PrivacySwapHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    IPoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PrivacySwapHook hook;
    address hookAddr;

    Currency currency0;
    Currency currency1;
    PoolKey key;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        // 1. Deploy PoolManager
        manager = new PoolManager(address(this));

        // 2. Deploy our hook - we'll etch it to the correct address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        hookAddr = address(flags);
        PrivacySwapHook impl = new PrivacySwapHook(manager, 3, address(0));
        vm.etch(hookAddr, address(impl).code);
        hook = PrivacySwapHook(hookAddr);

        // 3. Deploy routers
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // 4. Set admin + liquidityActivationBlocks and add swap router (storage vars not in etched bytecode)
        vm.store(address(hook), bytes32(uint256(0)), bytes32(uint256(uint160(address(this)))));
        vm.store(address(hook), bytes32(uint256(2)), bytes32(uint256(3))); // liquidityActivationBlocks = 3
        hook.addRouter(address(swapRouter));

        // 5. Deploy tokens
        MockERC20 token0 = new MockERC20("T0", "T0", 18);
        MockERC20 token1 = new MockERC20("T1", "T1", 18);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);

        if (address(token0) < address(token1)) {
            currency0 = Currency.wrap(address(token0));
            currency1 = Currency.wrap(address(token1));
        } else {
            currency0 = Currency.wrap(address(token1));
            currency1 = Currency.wrap(address(token0));
        }

        // 6. Approve routers
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // 7. Init pool with our hook
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        manager.initialize(key, SQRT_PRICE_1_1);

        // 8. Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
    }

    function test_swapWithEmptyHookData() public {
        // Simple swap without SwapIntent - should pass (backward compat)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            "" // empty hookData
        );
    }

    function test_swapWithSwapIntent() public {
        PoolId poolId = key.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number), // execution window starts now
            endBlock: uint64(block.number + 100),
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Privacy: Swap before execution window starts must revert
    function test_swapExecutionWindowNotStarted_Reverts() public {
        PoolId poolId = key.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number + 10), // window starts 10 blocks from now
            endBlock: uint64(block.number + 110),
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        vm.expectRevert(); // ExecutionWindowNotStarted
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Privacy: Swap after execution window expires must revert
    function test_swapExecutionWindowExpired_Reverts() public {
        vm.roll(100); // ensure block.number high enough for past window
        PoolId poolId = key.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number - 20), // window was 20 blocks ago
            endBlock: uint64(block.number - 1),     // expired last block
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        vm.expectRevert(); // ExecutionWindowExpired
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Privacy: Swap before min delay elapses must revert
    function test_swapMinDelayNotMet_Reverts() public {
        vm.roll(100); // ensure block.number high enough
        PoolId poolId = key.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number - 10), // window open
            endBlock: uint64(block.number + 90),
            minDelayBlocks: 5,                        // need 5 blocks since creation
            createdAtBlock: uint32(block.number - 1), // created 1 block ago
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        vm.expectRevert(); // MinDelayNotMet
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Privacy: Swap succeeds when min delay is satisfied
    function test_swapWithMinDelaySatisfied_Succeeds() public {
        vm.roll(100); // ensure block.number high enough
        PoolId poolId = key.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number - 20), // window open
            endBlock: uint64(block.number + 80),
            minDelayBlocks: 5,                         // need 5 blocks since creation
            createdAtBlock: uint32(block.number - 10), // created 10 blocks ago
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function test_swapWithSwapIntent_WrongPool_Reverts() public {
        PoolId wrongPoolId = PoolId.wrap(keccak256("wrong"));
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [wrongPoolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 56022770974786139918731938227}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function test_liquidityCooldown() public {
        // Add more liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e17,
                salt: bytes32(uint256(1)) // different salt = new position
            }),
            Constants.ZERO_BYTES
        );

        // Try to remove immediately - should revert (cooldown is 3 blocks)
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1e17,
                salt: bytes32(uint256(1))
            }),
            Constants.ZERO_BYTES
        );

        // Warp 4 blocks
        vm.roll(block.number + 4);

        // Now removal should work
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1e17,
                salt: bytes32(uint256(1))
            }),
            Constants.ZERO_BYTES
        );
    }

    /// @notice LP removal in same block as swap must revert (MEV: reaction sniping)
    function test_removalBlockedSameBlockAsSwap() public {
        PoolId poolId = key.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        bytes memory hookData = abi.encode(intent);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100,
                sqrtPriceLimitX96: 56022770974786139918731938227
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        // Same block: try to remove liquidity -> must revert
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1e17,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
    }

    /// @notice Routing entropy: intent with 2 allowed pools; swap uses deterministically selected pool
    function test_multiPoolRoutingEntropy() public {
        // Second pool: same pair, different fee
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(keyB, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            Constants.ZERO_BYTES
        );

        PoolId poolIdA = key.toId();
        PoolId poolIdB = keyB.toId();
        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolIdA, poolIdB, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 2,
            minAmountOut: 0,
            salt: bytes32(0)
        });

        // Use executor to get selected pool (blockhash-based selection)
        IntentStore intentStore = new IntentStore(address(0));
        PrivacySwapExecutor executor = new PrivacySwapExecutor(intentStore, swapRouter);
        intentStore.setExecutor(address(executor));
        hook.addRouter(address(swapRouter));
        uint256 intentId = intentStore.submitIntent(intent, 100);
        PoolId selected = executor.getSelectedPoolForIntent(intentId, block.number);
        PoolKey memory selectedKey = PoolId.unwrap(selected) == PoolId.unwrap(poolIdA) ? key : keyB;

        swapRouter.swap(
            selectedKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100,
                sqrtPriceLimitX96: 56022770974786139918731938227
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(intent)
        );
    }

    /// @notice Intent batching: 2 intents executed in one tx via executeBatch
    function test_executeBatch_TwoIntentsSameBlock() public {
        IntentStore intentStore = new IntentStore(address(0));
        PrivacySwapExecutor executor = new PrivacySwapExecutor(intentStore, swapRouter);
        intentStore.setExecutor(address(executor));
        hook.addRouter(address(swapRouter));

        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));

        address user1 = address(0x1);
        address user2 = address(0x2);
        token0.mint(user1, 1e18);
        token1.mint(user1, 1e18);
        token0.mint(user2, 1e18);
        token1.mint(user2, 1e18);

        vm.startPrank(user1);
        token1.approve(address(executor), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(user2);
        token1.approve(address(executor), type(uint256).max);
        vm.stopPrank();

        PoolId poolId = key.toId();
        uint64 startBlock = uint64(block.number + 1);
        uint64 endBlock = uint64(block.number + 100);

        SwapIntent memory intent1 = SwapIntent({
            startBlock: startBlock,
            endBlock: endBlock,
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        SwapIntent memory intent2 = SwapIntent({
            startBlock: startBlock,
            endBlock: endBlock,
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(uint256(1))
        });

        vm.prank(user1);
        uint256 id1 = intentStore.submitIntent(intent1, 50);
        vm.prank(user2);
        uint256 id2 = intentStore.submitIntent(intent2, 50);

        vm.roll(block.number + 1);

        PoolId selected1 = executor.getSelectedPoolForIntent(id1, block.number);
        PoolId selected2 = executor.getSelectedPoolForIntent(id2, block.number);
        assertEq(PoolId.unwrap(selected1), PoolId.unwrap(selected2));
        assertEq(PoolId.unwrap(selected1), PoolId.unwrap(poolId));

        uint256 bal0Before1 = token0.balanceOf(user1);
        uint256 bal0Before2 = token0.balanceOf(user2);

        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = key;
        keys[1] = key;
        IPoolManager.SwapParams[] memory params = new IPoolManager.SwapParams[](2);
        params[0] = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -50,
            sqrtPriceLimitX96: 158456325028528675187087900672
        });
        params[1] = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -50,
            sqrtPriceLimitX96: 158456325028528675187087900672
        });

        executor.executeBatch(
            _toArray(id1, id2),
            keys,
            params
        );

        assertGt(token0.balanceOf(user1), bal0Before1);
        assertGt(token0.balanceOf(user2), bal0Before2);
        assertTrue(intentStore.getIntent(id1).executed);
        assertTrue(intentStore.getIntent(id2).executed);
    }

    function _toArray(uint256 a, uint256 b) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }
}
