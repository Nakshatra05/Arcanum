// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract PrivacySwapHookTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager poolManager;
    PrivacySwapHook hook;
    address router = address(0x1234);

    function setUp() public {
        poolManager = IPoolManager(address(new PoolManager(address(this))));
        hook = new PrivacySwapHook(poolManager, 5, address(0));
        hook.addRouter(router);
    }

    function test_Constructor() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.liquidityActivationBlocks(), 5);
    }

    function test_AddRemoveRouter() public {
        address newRouter = address(0x5678);
        assertFalse(hook.allowedRouters(newRouter));
        hook.addRouter(newRouter);
        assertTrue(hook.allowedRouters(newRouter));
        hook.removeRouter(newRouter);
        assertFalse(hook.allowedRouters(newRouter));
    }

    function test_EncodeDecodeSwapIntent() public pure {
        PoolId poolId = PoolId.wrap(keccak256("test"));
        SwapIntent memory intent = SwapIntent({
            startBlock: 100,
            endBlock: 200,
            minDelayBlocks: 2,
            createdAtBlock: 0,
                allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 1e18,
            salt: bytes32(0)
        });
        bytes memory encoded = abi.encode(intent);
        SwapIntent memory decoded = abi.decode(encoded, (SwapIntent));
        assertEq(decoded.startBlock, 100);
        assertEq(decoded.endBlock, 200);
        assertEq(decoded.allowedPoolCount, 1);
    }

    function test_Permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
    }
}
