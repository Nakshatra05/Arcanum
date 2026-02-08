// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Execute a swap against an existing deployment
/// @dev Requires env: POOL_MANAGER, SWAP_ROUTER, TOKEN0, TOKEN1, HOOK
///      Optional: SWAP_AMOUNT (default 100e18), USE_PRIVACY (default true)
/// Run: forge script script/ExecuteSwap.s.sol --rpc-url $RPC --broadcast
contract ExecuteSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_2 = 56022770974786139918731938227;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address swapRouterAddr = vm.envAddress("SWAP_ROUTER");
        address token0Addr = vm.envAddress("TOKEN0");
        address token1Addr = vm.envAddress("TOKEN1");
        address hookAddr = vm.envAddress("HOOK");

        uint256 amount = vm.envOr("SWAP_AMOUNT", uint256(100e18));
        bool usePrivacy = vm.envOr("USE_PRIVACY", true);

        Currency currency0 = Currency.wrap(token0Addr);
        Currency currency1 = Currency.wrap(token1Addr);
        if (token0Addr > token1Addr) {
            currency0 = Currency.wrap(token1Addr);
            currency1 = Currency.wrap(token0Addr);
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast(pk);

        PoolSwapTest swapRouter = PoolSwapTest(swapRouterAddr);

        bytes memory hookData;
        if (usePrivacy) {
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
            hookData = abi.encode(intent);
            console.log("Executing privacy swap, amount:", amount);
        } else {
            console.log("Executing simple swap, amount:", amount);
        }

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: SQRT_PRICE_1_2
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );

        vm.stopBroadcast();
        console.log("Swap OK");
    }
}
