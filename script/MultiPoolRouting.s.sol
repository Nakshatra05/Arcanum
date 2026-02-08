// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IntentStore} from "../src/IntentStore.sol";
import {PrivacySwapExecutor} from "../src/PrivacySwapExecutor.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Multi-pool routing entropy: same token pair, 2 pools, intent with allowedPoolIds=[A,B].
/// @dev Routing selection uses blockhash(block.number-1) % 2 — deterministic, unpredictable at submission.
///      Executor must use the selected pool; hook enforces via requirePoolMatchesSelection.
///      Full flow verified in test_multiPoolRoutingEntropy.
/// Run: forge script script/MultiPoolRouting.s.sol --rpc-url http://localhost:8545
contract MultiPoolRouting is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_PRICE_4_1 = 158456325028528675187087900672; // for zeroForOne=false need limit > current

    function run() external {
        uint256 deployerPk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

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
        PoolModifyLiquidityTest modifyRouter = new PoolModifyLiquidityTest(manager);
        hook.addRouter(address(swapRouter));
        hook.addRouter(address(modifyRouter));

        IntentStore intentStore = new IntentStore(address(0));
        PrivacySwapExecutor executor = new PrivacySwapExecutor(intentStore, swapRouter);
        intentStore.setExecutor(address(executor));

        MockERC20 token0 = new MockERC20("T0", "T0", 18);
        MockERC20 token1 = new MockERC20("T1", "T1", 18);
        token0.mint(deployer, 1e32);
        token1.mint(deployer, 1e32);

        Currency currency0 = address(token0) < address(token1) ? Currency.wrap(address(token0)) : Currency.wrap(address(token1));
        Currency currency1 = address(token0) < address(token1) ? Currency.wrap(address(token1)) : Currency.wrap(address(token0));

        // Pool A: 0.3% fee, tickSpacing 60
        PoolKey memory keyA = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyA, SQRT_PRICE_1_1);
        PoolId poolIdA = keyA.toId();

        // Pool B: 0.05% fee, tickSpacing 10
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyB, SQRT_PRICE_1_1);
        PoolId poolIdB = keyB.toId();

        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyRouter), type(uint256).max);
        token1.approve(address(modifyRouter), type(uint256).max);
        token1.approve(address(executor), type(uint256).max);

        // Add liquidity to both pools
        modifyRouter.modifyLiquidity(
            keyA,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: bytes32(0)}),
            Constants.ZERO_BYTES
        );
        modifyRouter.modifyLiquidity(
            keyB,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            Constants.ZERO_BYTES
        );
        console.log("Liquidity added to Pool A (0.3%) and Pool B (0.05%)");

        // Intent: allowed pools [A, B], selection = blockhash(block-1) % 2
        uint64 startBlock = uint64(block.number + 1);
        uint64 endBlock = uint64(block.number + 100);
        SwapIntent memory intent = SwapIntent({
            startBlock: startBlock,
            endBlock: endBlock,
            minDelayBlocks: 1,
            createdAtBlock: 0,
            allowedPoolIds: [poolIdA, poolIdB, PoolId.wrap(bytes32(0)), PoolId.wrap(bytes32(0))],
            allowedPoolCount: 2,
            minAmountOut: 0,
            salt: bytes32(0)
        });
        uint256 intentId = intentStore.submitIntent(intent, 100e18);

        // Next block: execute
        vm.roll(block.number + 1);
        PoolId selectedPoolId = executor.getSelectedPoolForIntent(intentId, block.number);
        PoolKey memory selectedKey = PoolId.unwrap(selectedPoolId) == PoolId.unwrap(poolIdA) ? keyA : keyB;
        console.log("Selected pool:", PoolId.unwrap(selectedPoolId) == PoolId.unwrap(poolIdA) ? "A (0.3%)" : "B (0.05%)");

        executor.executeIntent(intentId, selectedKey, SQRT_PRICE_4_1);
        vm.stopBroadcast();

        console.log("Swap executed via routing entropy");
        console.log("--- Multi-pool routing complete ---");
    }
}
