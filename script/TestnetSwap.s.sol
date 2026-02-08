// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PrivacySwapHook} from "../src/PrivacySwapHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @notice Full testnet flow on Unichain Sepolia: deploy hook + routers, init pool, add liquidity, swap
/// @dev Requires: PRIVATE_KEY, native ETH + USDC on Unichain Sepolia (bridge from Sepolia faucet)
///      ETH is wrapped to WETH automatically; Uniswap uses WETH (ERC20), not native ETH.
/// Run: PRIVATE_KEY=0x... forge script script/TestnetSwap.s.sol --rpc-url https://sepolia.unichain.org --broadcast
contract TestnetSwap is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    // For zeroForOne=false (sell WETH for USDC), limit must be > current price; use 2:1 or 4:1
    uint160 constant SQRT_PRICE_2_1 = 112045541949572279837463876454;
    uint160 constant SQRT_PRICE_4_1 = 158456325028528675187087900672;

    // Unichain Sepolia
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
            5, // liquidityActivationBlocks
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
        console.log("PrivacySwapHook:", address(hook));

        // 2. Deploy routers and add to allowlist
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        PoolModifyLiquidityTest modifyRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        hook.addRouter(address(swapRouter));
        console.log("SwapRouter:", address(swapRouter));
        console.log("ModifyLiquidityRouter:", address(modifyRouter));

        // 3. Wrap native ETH to WETH (Uniswap uses WETH, not native ETH)
        uint256 wrapAmount = 0.02 ether; // enough for liquidity + swaps
        if (deployer.balance >= wrapAmount) {
            (bool ok,) = payable(WETH).call{value: wrapAmount}(abi.encodeWithSignature("deposit()"));
            require(ok, "WETH wrap failed");
            console.log("Wrapped", wrapAmount, "ETH to WETH");
        }

        // 4. Currencies (PoolManager requires currency0 < currency1 by address)
        Currency currency0 = Currency.wrap(USDC);  // 0x31d0... < 0x4200...
        Currency currency1 = Currency.wrap(WETH);

        // 5. Approve routers (caller must have WETH/USDC)
        IERC20Minimal(WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(WETH).approve(address(modifyRouter), type(uint256).max);
        IERC20Minimal(USDC).approve(address(modifyRouter), type(uint256).max);

        // 6. Init pool
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);
        PoolId poolId = key.toId();
        console.log("Pool initialized");

        // 7. Add liquidity (2e9 = ~12 USDC in pool for noticeable swap output; 1e9 was ~6 USDC)
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
        console.log("Liquidity added");

        // 8. Simple swap (WETH -> USDC)
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(0.01e18), // 0.01 WETH in
                sqrtPriceLimitX96: SQRT_PRICE_2_1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _logUsdcBalance(deployer);

        // 9. Privacy swap
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
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(0.005e18),
                sqrtPriceLimitX96: SQRT_PRICE_4_1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(intent)
        );
        _logUsdcBalance(deployer);

        vm.stopBroadcast();

        console.log("--- Testnet addresses ---");
        console.log("HOOK:", address(hook));
        console.log("SWAP_ROUTER:", address(swapRouter));
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("--- Explorer (Unichain Sepolia, chain 1301) ---");
        console.log("Hook:", address(hook));
        console.log("View: https://sepolia.uniscan.xyz/");
    }

    function _logUsdcBalance(address who) internal view {
        console.log("  USDC balance:", IERC20Minimal(USDC).balanceOf(who) / 1e6);
    }
}
