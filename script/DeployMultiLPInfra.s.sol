// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IntentStore} from "../src/IntentStore.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";
import {BatchModifyLiquidityRouter} from "../src/BatchModifyLiquidityRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice Deploy multi-LP infra once. Uses Uniswap v4 batch router (one unlock = 3 LP positions).
/// @dev Run: PRIVATE_KEY=0x... forge script script/DeployMultiLPInfra.s.sol --rpc-url https://sepolia.unichain.org --broadcast
contract DeployMultiLPInfra is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    int256 constant LIQUIDITY_DELTA = 7e8; // Fits ~14 USDC balance (1e9 * 3 needed ~18 USDC)

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Deploy hook
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), 5, deployer);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            create2Deployer, flags, type(PrivacySwapHook).creationCode, constructorArgs
        );
        PrivacySwapHook hook = new PrivacySwapHook{salt: salt}(IPoolManager(POOL_MANAGER), 5, deployer);
        require(address(hook) == hookAddr, "HookMiner mismatch");

        // 2. Deploy swap router, batch modify router, IntentStore, Executor
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        BatchModifyLiquidityRouter batchRouter = new BatchModifyLiquidityRouter(IPoolManager(POOL_MANAGER));
        IntentStore intentStore = new IntentStore(address(0));
        PrivacySwapExecutor executor = new PrivacySwapExecutor(intentStore, swapRouter);
        intentStore.setExecutor(address(executor));

        hook.addRouter(address(swapRouter));
        hook.addRouter(address(batchRouter));

        // 3. Wrap ETH, approvals, init pool
        uint256 wrapAmount = 0.03 ether; // 3 × LP
        if (deployer.balance >= wrapAmount) {
            (bool ok,) = payable(WETH).call{value: wrapAmount}(abi.encodeWithSignature("deposit()"));
            require(ok, "WETH wrap failed");
        }

        Currency currency0 = Currency.wrap(USDC);
        Currency currency1 = Currency.wrap(WETH);
        IERC20Minimal(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(WETH).approve(address(batchRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(batchRouter), type(uint256).max);
        IERC20Minimal(WETH).approve(address(executor), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);
        PoolId poolId = key.toId();

        // 4. Add 3 LP positions in one unlock (Uniswap v4 batching)
        IPoolManager.ModifyLiquidityParams[] memory params = new IPoolManager.ModifyLiquidityParams[](3);
        params[0] = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: LIQUIDITY_DELTA,
            salt: bytes32(uint256(1))
        });
        params[1] = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: LIQUIDITY_DELTA,
            salt: bytes32(uint256(2))
        });
        params[2] = IPoolManager.ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: LIQUIDITY_DELTA,
            salt: bytes32(uint256(3))
        });
        batchRouter.batchModifyLiquidity(key, params, Constants.ZERO_BYTES);

        vm.stopBroadcast();

        // 5. Write deployments JSON
        string memory path = string.concat("script/deployments-", vm.toString(block.chainid), ".json");
        string memory root = "deployments";
        vm.serializeAddress(root, "hook", address(hook));
        vm.serializeAddress(root, "swapRouter", address(swapRouter));
        vm.serializeAddress(root, "batchRouter", address(batchRouter));
        vm.serializeAddress(root, "intentStore", address(intentStore));
        vm.serializeAddress(root, "executor", address(executor));
        string memory finalJson = vm.serializeBytes32(root, "poolId", PoolId.unwrap(poolId));
        vm.writeJson(finalJson, path);

        console.log("Deployments saved to", path);
        console.log("HOOK:", address(hook));
        console.log("BATCH_ROUTER:", address(batchRouter));
        console.log("INTENT_STORE:", address(intentStore));
    }
}
