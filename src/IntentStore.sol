// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwapIntent} from "./types/SwapIntent.sol";
import {SwapIntentLibrary, SwapIntentConstants} from "./libraries/SwapIntentLibrary.sol";

/// @title IntentStore
/// @notice Stores swap intents for deferred execution. Enables timing + routing privacy.
/// @dev Intents are stored onchain; executors pick them up in future blocks.
contract IntentStore {
    address public executor;
    struct StoredIntent {
        SwapIntent intent;
        address beneficiary;   // who receives the swap output
        address payer;         // who provides input tokens (must approve executor)
        uint256 amountIn;      // input amount (e.g. WETH wei for WETH->USDC)
        bool executed;
    }

    StoredIntent[] public intents;

    event IntentSubmitted(uint256 indexed intentId, address indexed beneficiary, uint64 startBlock, uint64 endBlock);
    event IntentExecuted(uint256 indexed intentId);

    modifier onlyExecutor() {
        require(msg.sender == executor, "only executor");
        _;
    }

    constructor(address _executor) {
        executor = _executor; // can be address(0), set via setExecutor after deploy
    }

    /// @notice Set executor (call once after deploying PrivacySwapExecutor)
    function setExecutor(address _executor) external {
        require(executor == address(0) || msg.sender == executor, "only executor or init");
        executor = _executor;
    }

    function markExecuted(uint256 intentId) external onlyExecutor {
        require(intentId < intents.length && !intents[intentId].executed, "invalid or executed");
        intents[intentId].executed = true;
        emit IntentExecuted(intentId);
    }

    /// @notice Submit a swap intent for deferred execution
    /// @param intent The SwapIntent (execution window, allowed pools, minAmountOut)
    /// @param amountIn Input amount in wei/token units (e.g. 0.01e18 for WETH)
    function submitIntent(SwapIntent memory intent, uint256 amountIn) external returns (uint256 intentId) {
        SwapIntentLibrary.validate(intent);
        require(amountIn > 0, "amountIn must be > 0");

        intentId = intents.length;
        intent.createdAtBlock = uint32(block.number);
        intents.push(StoredIntent({
            intent: intent,
            beneficiary: msg.sender,
            payer: msg.sender,
            amountIn: amountIn,
            executed: false
        }));

        emit IntentSubmitted(intentId, msg.sender, intent.startBlock, intent.endBlock);
    }

    /// @notice Get intent by ID
    function getIntent(uint256 intentId) external view returns (StoredIntent memory) {
        require(intentId < intents.length, "invalid intent");
        return intents[intentId];
    }

    /// @notice Check if intent is executable (in window, not yet executed)
    function isExecutable(uint256 intentId) external view returns (bool) {
        if (intentId >= intents.length) return false;
        StoredIntent storage s = intents[intentId];
        if (s.executed) return false;
        if (block.number < s.intent.startBlock) return false;
        if (block.number > s.intent.endBlock) return false;
        return true;
    }
}
