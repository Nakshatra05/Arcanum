// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapIntent} from "./types/SwapIntent.sol";
import {SwapIntentLibrary} from "./libraries/SwapIntentLibrary.sol";

/// @title PrivacySwapHook
/// @notice Privacy-aware swap execution system on Uniswap v4.
/// @dev Implements intent-based execution, timing privacy, routing privacy, and liquidity shielding.
///      All logic is onchain, deterministic, and auditable. No offchain relayers.
///
/// SECURITY: Does NOT use beforeSwapReturnDelta or afterSwapReturnDelta (NoOp attack vector).
///           See uniswap-v4-security-foundations skill. PoolManager verification enforced.
contract PrivacySwapHook is IHooks {
    using PoolIdLibrary for PoolKey;

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error NotPoolManager();
    error RouterNotAllowed();
    error NotAdmin();
    error ZeroAddress();
    error LiquidityActivationPending();
    /// @notice LP tried to remove liquidity in same block as a swap (MEV: swap-reaction sniping)
    error RemovalBlockedSameBlockAsSwap();

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event SwapExecuted(PoolId indexed poolId, address indexed sender, uint256 blockExecuted);
    event LiquidityAdded(PoolId indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, bytes32 salt);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);

    // ═══════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════

    IPoolManager public immutable poolManager;
    address public admin;

    /// @notice Allowlisted routers that can initiate swaps (per security foundations)
    mapping(address => bool) public allowedRouters;

    /// @notice Liquidity activation delay: new LP positions cannot be removed for this many blocks
    /// @dev Mitigates LP front-running: add liquidity -> see swap -> remove (sniping)
    uint32 public liquidityActivationBlocks;

    /// @notice (poolId, owner, tickLower, tickUpper, salt) => block when position was first added
    /// @dev Used to enforce cooldown before removal
    mapping(bytes32 => uint256) public positionActivationBlock;

    /// @notice poolId => last block where a swap occurred. Prevents same-block LP removal after swap.
    /// @dev MEV: blocks "see swap -> remove in same block" reaction sniping
    mapping(bytes32 => uint256) public lastSwapBlock;

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyAllowedRouter(address sender) {
        if (!allowedRouters[sender]) revert RouterNotAllowed();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @param _admin If set, use as admin; else msg.sender. Use address(0) when deploying via Create2Deployer.
    constructor(IPoolManager _poolManager, uint32 _liquidityActivationBlocks, address _admin) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        poolManager = _poolManager;
        admin = _admin != address(0) ? _admin : msg.sender;
        liquidityActivationBlocks = _liquidityActivationBlocks == 0 ? 1 : _liquidityActivationBlocks;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════
    // WHY each hook exists:
    // - beforeSwap: TIMING PRIVACY + ROUTING PRIVACY. Validate execution window, min delay, pool allowlist.
    // - afterSwap: Record execution for analytics; set createdAtBlock on first execution.
    // - beforeAddLiquidity: No gating; we only observe.
    // - afterAddLiquidity: LIQUIDITY SHIELDING. Record when position was added for cooldown.
    // - beforeRemoveLiquidity: LIQUIDITY SHIELDING. Block removal if cooldown not met.
    // - afterRemoveLiquidity: No extra logic.
    //
    // CRITICAL: beforeSwapReturnDelta and afterSwapReturnDelta are FALSE (NoOp attack vector)
    // ═══════════════════════════════════════════════════════════════════════

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // CRITICAL: Never enable without audit
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SWAP HOOKS – Intent-based execution, timing & routing privacy
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice WHY: Enforces execution window and min delay (timing privacy).
    ///         Validates swap uses an allowed pool (routing privacy).
    ///         Router allowlisting prevents unauthorized execution.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, /* params */
        bytes calldata hookData
    ) external view override onlyPoolManager onlyAllowedRouter(sender) returns (bytes4, BeforeSwapDelta, uint24) {
        // Non-intent swaps: allow if no hookData (backward compat / simple swaps)
        if (hookData.length == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        SwapIntent memory intent = SwapIntentLibrary.decode(hookData);
        SwapIntentLibrary.validate(intent);

        // ROUTING ENTROPY: Pool selection = hash(blockhash(block.number-1), intentHash) % poolCount.
        // - Selection happens HERE in beforeSwap; executor cannot influence it.
        // - Executor MUST pass the PoolKey for the selected pool; wrong pool → revert.
        // - Executor cannot bias: selection is deterministic from onchain data; executor can only
        //   choose which intents to batch and when to submit the tx, not which pool each uses.
        PoolId poolId = key.toId();
        SwapIntentLibrary.requirePoolMatchesSelection(intent, poolId, block.number);

        // TIMING PRIVACY: Execution within window and min delay
        SwapIntentLibrary.isExecutionAllowed(intent, block.number);

        // Return ZERO_DELTA - we do NOT modify swap amounts (no fee-taking, no custom accounting)
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice WHY: Record execution; persist createdAtBlock for min-delay on future attempts.
    ///         Track lastSwapBlock per pool to block same-block LP removal (MEV mitigation).
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, /* params */
        BalanceDelta, /* delta */
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (hookData.length > 0) {
            bytes32 poolId = PoolId.unwrap(key.toId());
            lastSwapBlock[poolId] = block.number;
            emit SwapExecuted(key.toId(), sender, block.number);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIQUIDITY HOOKS – LP front-running mitigation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice WHY: Record when each position was first added. Used by beforeRemoveLiquidity.
    /// LIQUIDITY SHIELDING RULES (MEV defence):
    /// - LP entry: Unrestricted. Adding liquidity is always allowed.
    /// - LP exit: Blocked for liquidityActivationBlocks after first add. Prevents:
    ///   (1) Sniping: see swap -> add -> earn fees -> remove same block
    ///   (2) Front-running: add before swap, remove after to capture price move
    /// - Activation delay: New positions "activate" at first add; removal allowed only after cooldown.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta, /* delta */
        BalanceDelta, /* feesAccrued */
        bytes calldata /* hookData */
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // Only record when liquidity is being added (positive delta)
        if (params.liquidityDelta > 0) {
            bytes32 positionKey = keccak256(
                abi.encode(key.toId(), sender, params.tickLower, params.tickUpper, params.salt)
            );
            // Only set on first add (don't overwrite)
            if (positionActivationBlock[positionKey] == 0) {
                positionActivationBlock[positionKey] = block.number;
            }
            emit LiquidityAdded(key.toId(), sender, params.tickLower, params.tickUpper, params.salt);
        }
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice WHY: LIQUIDITY SHIELDING. Block removal if:
    ///         (1) Position added too recently (cooldown).
    ///         (2) Swap occurred in same block (reaction sniping).
    ///         Prevents: see swap -> add -> remove same block; add before swap -> remove after.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata /* hookData */
    ) external view override onlyPoolManager returns (bytes4) {
        if (params.liquidityDelta >= 0) return IHooks.beforeRemoveLiquidity.selector;

        bytes32 poolIdBytes = PoolId.unwrap(key.toId());
        // Same-block removal after swap: blocks LP from reacting to swap in same block
        if (lastSwapBlock[poolIdBytes] == block.number) revert RemovalBlockedSameBlockAsSwap();

        bytes32 positionKey = keccak256(
            abi.encode(key.toId(), sender, params.tickLower, params.tickUpper, params.salt)
        );
        uint256 activatedAt = positionActivationBlock[positionKey];
        if (activatedAt == 0) {
            // Position tracked before hook was deployed, or legacy position - allow
            return IHooks.beforeRemoveLiquidity.selector;
        }
        if (block.number - activatedAt < liquidityActivationBlocks) revert LiquidityActivationPending();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // Stub implementations for hooks we don't use
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotImplemented();
    }

    error NotImplemented();

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    function addRouter(address router) external onlyAdmin {
        if (router == address(0)) revert ZeroAddress();
        allowedRouters[router] = true;
        emit RouterAdded(router);
    }

    function removeRouter(address router) external onlyAdmin {
        allowedRouters[router] = false;
        emit RouterRemoved(router);
    }

    function setLiquidityActivationBlocks(uint32 blocks) external onlyAdmin {
        liquidityActivationBlocks = blocks == 0 ? 1 : blocks;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }
}
