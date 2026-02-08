// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IntentStore} from "../src/IntentStore.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice Submit intents and execute (1-2 per run). For 2 intents same-direction, pool needs deep liquidity.
/// @dev Run: PRIVATE_KEY=0x... forge script script/RunBatchSwap.s.sol --rpc-url https://sepolia.unichain.org --broadcast
contract RunBatchSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_2_1 = 112045541949572279837463876454;
    uint160 constant SQRT_PRICE_4_1 = 158456325028528675187087900672;
    /// @dev For zeroForOne=false: limit must be > current; stay within liquidity range (-120..120).

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        string memory chainIdStr = vm.toString(block.chainid);
        string memory deploymentsPath = string.concat("script/deployments-", chainIdStr, ".json");
        string memory json = vm.readFile(deploymentsPath);
        address executorAddr = vm.parseJsonAddress(json, ".executor");
        bytes32 poolIdBytes = vm.parseJsonBytes32(json, ".poolId");

        IntentStore intentStore = IntentStore(vm.parseJsonAddress(json, ".intentStore"));
        PrivacySwapExecutor executor = PrivacySwapExecutor(executorAddr);
        PoolId poolId = PoolId.wrap(poolIdBytes);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(vm.parseJsonAddress(json, ".hook"))
        });

        vm.startBroadcast(pk);

        IERC20Minimal(WETH).approve(executorAddr, type(uint256).max);

        uint64 startBlock = uint64(block.number);
        uint64 endBlock = uint64(block.number + 100);
        // minDelayBlocks: 1 required by deployed IntentStore (compatible with MIN_DELAY_BLOCKS 0 or 1)
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

        uint256 amountEach = 0.00005 ether; // Small to avoid exhausting pool liquidity (2x same-direction swaps)
        uint256 id1 = intentStore.submitIntent(intent1, amountEach);
        uint256 id2 = intentStore.submitIntent(intent2, amountEach);

        vm.roll(block.number + 1); // Satisfy minDelayBlocks: 1 (1 block since creation)

        // Execute both intents. Use SQRT_PRICE_2_1 then SQRT_PRICE_4_1 so both stay in liquidity range (-120..120).
        executor.executeIntent(id1, key, SQRT_PRICE_2_1);
        executor.executeIntent(id2, key, SQRT_PRICE_4_1);

        vm.stopBroadcast();
        console.log("Batch executed, intent ids:", id1, id2);
    }
}
