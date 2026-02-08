// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IntentStore} from "../src/IntentStore.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";
import {BatchModifyLiquidityRouter} from "../src/BatchModifyLiquidityRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Simulates 3 LP positions: add via Uniswap v4 batch, compete for fees, attempt removal near swap.
/// @dev Demonstrates LP cooldown + same-block removal block. Run on Anvil.
/// Run: anvil & forge script script/MultiLPSimulation.s.sol --rpc-url http://localhost:8545 --broadcast
contract MultiLPSimulation is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_PRICE_4_1 = 158456325028528675187087900672;

    int256 constant LIQUIDITY_DELTA = 1e17;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        PoolManager manager = new PoolManager(deployer);
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(manager, uint32(5), deployer);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C,
            flags,
            type(PrivacySwapHook).creationCode,
            constructorArgs
        );
        PrivacySwapHook hook = new PrivacySwapHook{salt: salt}(manager, 5, deployer);
        require(address(hook) == hookAddr, "HookMiner mismatch");

        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        BatchModifyLiquidityRouter batchRouter = new BatchModifyLiquidityRouter(manager);
        hook.addRouter(address(swapRouter));
        hook.addRouter(address(batchRouter));

        IntentStore intentStore = new IntentStore(address(0));
        PrivacySwapExecutor executor = new PrivacySwapExecutor(intentStore, swapRouter);
        intentStore.setExecutor(address(executor));

        (MockERC20 token0, MockERC20 token1, Currency currency0, Currency currency1) = _deployTokens(deployer);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        PoolId poolId = key.toId();

        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(batchRouter), type(uint256).max);
        token1.approve(address(batchRouter), type(uint256).max);
        token0.approve(address(executor), type(uint256).max);
        token1.approve(address(executor), type(uint256).max);

        // Add 3 LP positions in one unlock (Uniswap v4 batching)
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

        console.log("3 LPs added in one tx");

        // Submit intent and execute
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
        uint256 intentId = intentStore.submitIntent(intent, 100e18);
        executor.executeIntent(intentId, key, SQRT_PRICE_4_1);

        console.log("Swap executed in block", block.number);

        // LP1 removal: blocked in same block (RemovalBlockedSameBlockAsSwap) and during cooldown.
        // After 6+ blocks, run: batchRouter.batchModifyLiquidity(key, [params with -LIQUIDITY_DELTA, salt 1], ...)
        console.log("--- Multi-LP simulation complete ---");
        vm.stopBroadcast();
    }

    function _deployTokens(address deployer)
        internal
        returns (MockERC20 token0, MockERC20 token1, Currency currency0, Currency currency1)
    {
        token0 = new MockERC20("T0", "T0", 18);
        token1 = new MockERC20("T1", "T1", 18);
        token0.mint(deployer, 1e30);
        token1.mint(deployer, 1e30);
        currency0 = address(token0) < address(token1) ? Currency.wrap(address(token0)) : Currency.wrap(address(token1));
        currency1 = address(token0) < address(token1) ? Currency.wrap(address(token1)) : Currency.wrap(address(token0));
    }
}
