// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapIntent} from "../src/types/SwapIntent.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Full local flow: deploy stack, init pool, add liquidity, execute swap (simple + privacy)
/// @dev Run: anvil & forge script script/LocalSwap.s.sol --rpc-url http://localhost:8545 --broadcast
///      Or: forge script script/LocalSwap.s.sol --rpc-url http://localhost:8545 --broadcast --skip-simulation
contract LocalSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_PRICE_1_2 = 56022770974786139918731938227;
    uint160 constant SQRT_PRICE_1_4 = 39614081257132168796771975168;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Deploy PoolManager
        PoolManager manager = new PoolManager(deployer);
        console.log("PoolManager:", address(manager));

        // 2. Deploy hook via CREATE2 (forge uses Create2Deployer 0x4e59... when broadcasting salted deploy)
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes memory constructorArgs = abi.encode(manager, uint32(3), deployer);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            create2Deployer, flags, type(PrivacySwapHook).creationCode, constructorArgs
        );
        PrivacySwapHook hook = new PrivacySwapHook{salt: salt}(manager, 3, deployer);
        require(address(hook) == hookAddr, "HookMiner address mismatch");
        console.log("PrivacySwapHook:", address(hook));

        // 3. Deploy routers
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest modifyRouter = new PoolModifyLiquidityTest(manager);
        hook.addRouter(address(swapRouter));
        console.log("SwapRouter:", address(swapRouter));
        console.log("ModifyLiquidityRouter:", address(modifyRouter));

        // 4. Deploy tokens
        MockERC20 token0 = new MockERC20("Token0", "T0", 18);
        MockERC20 token1 = new MockERC20("Token1", "T1", 18);
        token0.mint(deployer, 1e30);
        token1.mint(deployer, 1e30);

        Currency currency0 = address(token0) < address(token1) ? Currency.wrap(address(token0)) : Currency.wrap(address(token1));
        Currency currency1 = address(token0) < address(token1) ? Currency.wrap(address(token1)) : Currency.wrap(address(token0));

        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyRouter), type(uint256).max);
        token1.approve(address(modifyRouter), type(uint256).max);

        console.log("Token0:", Currency.unwrap(currency0));
        console.log("Token1:", Currency.unwrap(currency1));

        // 5. Init pool
        PoolKey memory key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);
        PoolId poolId = key.toId();
        console.log("PoolId (bytes32):");
        console.logBytes32(PoolId.unwrap(poolId));

        // 6. Add liquidity
        modifyRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            Constants.ZERO_BYTES
        );
        console.log("Liquidity added");

        // 7. Simple swap (no SwapIntent)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(100e18),
                sqrtPriceLimitX96: SQRT_PRICE_1_2
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console.log("Simple swap OK");

        // 8. Privacy swap (with SwapIntent) - use lower price limit since first swap moved price
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
        bytes memory hookData = abi.encode(intent);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(50e18),
                sqrtPriceLimitX96: SQRT_PRICE_1_4
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        console.log("Privacy swap OK");

        vm.stopBroadcast();

        console.log("--- Done. Addresses logged above.");
    }
}
