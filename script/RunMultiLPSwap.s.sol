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

/// @notice Single swap: submit intent + execute in one script (same block).
/// @dev Requires IntentStore deployed with MIN_DELAY_BLOCKS=0. Redeploy via DeployMultiLPInfra if needed.
/// Run: PRIVATE_KEY=0x... forge script script/RunMultiLPSwap.s.sol --rpc-url https://sepolia.unichain.org --broadcast
contract RunMultiLPSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_4_1 = 158456325028528675187087900672;

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

        SwapIntent memory intent = SwapIntent({
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            minDelayBlocks: 0,
            createdAtBlock: 0,
            allowedPoolIds: [poolId, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 1,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        uint256 intentId = intentStore.submitIntent(intent, 0.0005 ether);
        executor.executeIntent(intentId, key, SQRT_PRICE_4_1);

        vm.stopBroadcast();
        console.log("Swap executed, intent id:", intentId);
    }
}
