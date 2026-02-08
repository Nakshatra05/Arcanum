// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IntentStore} from "../src/IntentStore.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {AddLiquidityHelper} from "../src/AddLiquidityHelper.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice Deploy fresh contracts + init pool + add liquidity for ONE swap.
/// @dev Run this BEFORE each swap when you're the only LP (pool gets consumed after swap).
///      Then use frontend or ExecuteIntent.s.sol to submit + execute.
/// Run: PRIVATE_KEY=0x... forge script script/DeployAndPrepareSwap.s.sol --rpc-url https://sepolia.unichain.org --broadcast
contract DeployAndPrepareSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Deploy PrivacySwapHook
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            5,
            deployer
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            create2Deployer, flags, type(PrivacySwapHook).creationCode, constructorArgs
        );
        PrivacySwapHook hook = new PrivacySwapHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            5,
            deployer
        );
        require(address(hook) == hookAddr, "HookMiner address mismatch");

        // 2. Deploy routers, IntentStore, Executor
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        PoolModifyLiquidityTest modifyRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        IntentStore intentStore = new IntentStore(address(0));
        PrivacySwapExecutor executor = new PrivacySwapExecutor(intentStore, swapRouter);
        intentStore.setExecutor(address(executor));
        hook.addRouter(address(swapRouter));
        hook.addRouter(address(modifyRouter));

        // 3. Wrap ETH
        uint256 wrapAmount = 0.02 ether;
        if (deployer.balance >= wrapAmount) {
            (bool ok,) = payable(WETH).call{value: wrapAmount}(abi.encodeWithSignature("deposit()"));
            require(ok, "WETH wrap failed");
        }

        Currency currency0 = Currency.wrap(USDC);
        Currency currency1 = Currency.wrap(WETH);

        IERC20Minimal(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(WETH).approve(address(modifyRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(modifyRouter), type(uint256).max);
        IERC20Minimal(WETH).approve(address(executor), type(uint256).max);

        // 4. Init pool, add liquidity
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);
        PoolId poolId = key.toId();

        modifyRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 2e9,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );

        AddLiquidityHelper helper = new AddLiquidityHelper(
            IPoolManager(POOL_MANAGER),
            address(modifyRouter),
            USDC,
            WETH
        );

        vm.stopBroadcast();

        // Output for frontend / env
        console.log("--- Paste these into app/.env.local or frontend ---");
        console.log("NEXT_PUBLIC_INTENT_STORE=%s", address(intentStore));
        console.log("NEXT_PUBLIC_EXECUTOR=%s", address(executor));
        console.log("NEXT_PUBLIC_HOOK=%s", address(hook));
        console.log("NEXT_PUBLIC_MODIFY_ROUTER=%s", address(modifyRouter));
        console.log("NEXT_PUBLIC_ADD_LIQUIDITY_HELPER=%s", address(helper));
        console.log("--- Pool ready. Use frontend to swap or add liquidity. Intent IDs start at 0. ---");
    }
}
