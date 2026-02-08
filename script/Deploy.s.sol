// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();
        // Deploy with liquidity activation delay of 5 blocks
        new PrivacySwapHook(IPoolManager(vm.envAddress("POOL_MANAGER")), 5, address(0));
        vm.stopBroadcast();
    }
}
