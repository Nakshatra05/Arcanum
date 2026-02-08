// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Execute a submitted swap intent by ID
/// @dev Run: INTENT_ID=7 PRIVATE_KEY=0x... forge script script/ExecuteIntent.s.sol --rpc-url https://sepolia.unichain.org --broadcast
contract ExecuteIntent is Script {
    // Must match your deployment (same as frontend config)
    address constant EXECUTOR = 0x4887614937C5c762603aB7ABC0fb576B41Db767c;
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant HOOK = 0x1b33309710Fd3Cd6055c17ae5ed8Bc0380F086C0;
    uint160 constant SQRT_PRICE_4_1 = 158456325028528675187087900672;

    function run() external {
        uint256 intentId = vm.envUint("INTENT_ID");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        vm.startBroadcast(pk);
        PrivacySwapExecutor(EXECUTOR).executeIntent(intentId, key, SQRT_PRICE_4_1);
        vm.stopBroadcast();

        console.log("Intent", intentId, "executed");
    }
}
