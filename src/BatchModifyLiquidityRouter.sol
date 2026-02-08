// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolTestBase} from "@uniswap/v4-core/src/test/PoolTestBase.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Uniswap v4 native batching: multiple modifyLiquidity in one unlock.
/// @dev All positions live in this router, distinguished by salt. Caller provides tokens.
///      Per uniswap-v4-security-foundations: bounded loops to prevent OOG.
contract BatchModifyLiquidityRouter is PoolTestBase {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    /// @notice Max positions per batch (security: no unbounded loops)
    uint256 public constant MAX_BATCH_SIZE = 16;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct BatchCallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams[] params;
        bytes hookData;
    }

    /// @notice Add multiple LP positions in one tx. Caller must have approved this contract.
    function batchModifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams[] memory params,
        bytes memory hookData
    ) external payable {
        bytes memory cdata = abi.encode(BatchCallbackData(msg.sender, key, params, hookData));
        manager.unlock(cdata);

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "Not PoolManager");

        BatchCallbackData memory data = abi.decode(rawData, (BatchCallbackData));
        require(data.params.length <= MAX_BATCH_SIZE, "Batch too large");

        for (uint256 i = 0; i < data.params.length; i++) {
            (uint128 liquidityBefore,,) = manager.getPositionInfo(
                data.key.toId(), address(this), data.params[i].tickLower, data.params[i].tickUpper, data.params[i].salt
            );

            manager.modifyLiquidity(data.key, data.params[i], data.hookData);

            (uint128 liquidityAfter,,) = manager.getPositionInfo(
                data.key.toId(), address(this), data.params[i].tickLower, data.params[i].tickUpper, data.params[i].salt
            );

            require(
                int128(liquidityBefore) + data.params[i].liquidityDelta == int128(liquidityAfter),
                "liquidity change incorrect"
            );
        }

        (,, int256 delta0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 delta1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if (delta0 < 0) data.key.currency0.settle(manager, data.sender, uint256(-delta0), false);
        if (delta1 < 0) data.key.currency1.settle(manager, data.sender, uint256(-delta1), false);
        if (delta0 > 0) data.key.currency0.take(manager, data.sender, uint256(delta0), false);
        if (delta1 > 0) data.key.currency1.take(manager, data.sender, uint256(delta1), false);

        return "";
    }
}
