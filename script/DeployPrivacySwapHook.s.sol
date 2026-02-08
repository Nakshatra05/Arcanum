// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Deploy PrivacySwapHook for Uniswap v4
/// @dev Per v4-template and https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment:
///      Hook addresses must encode permission flags. Use HookMiner.find() + CREATE2.
///      Use --sender 0x4e59b44847b379578588920cA78FbF26c0B4956C to deploy via CREATE2 factory.
///      For Unichain: https://docs.unichain.org/docs/technical-information/contract-addresses
contract DeployPrivacySwapHook is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Unichain Sepolia PoolManager (from docs.unichain.org)
        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0x00B036B58a818B1BC34d502D3fE730Db729e62AC));

        // Flags for our hook permissions (beforeSwap, afterSwap, afterAddLiquidity, beforeRemoveLiquidity)
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr),
            5, // liquidityActivationBlocks
            deployer // admin when using Create2Deployer
        );
        (address hookAddress, bytes32 salt) = HookMiner.find(
            create2Deployer,
            flags,
            type(PrivacySwapHook).creationCode,
            constructorArgs
        );

        vm.startBroadcast(deployerPrivateKey);

        PrivacySwapHook hook = new PrivacySwapHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            5,
            deployer
        );

        require(address(hook) == hookAddress, "DeployPrivacySwapHook: address mismatch");

        hook.addRouter(deployer);

        vm.stopBroadcast();

        console.log("PrivacySwapHook deployed at:", address(hook));
        console.log("PoolManager:", poolManagerAddr);
    }
}
