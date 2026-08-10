// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Indexer surface for ticket-triggered canonical TOKEN purchases.
interface IAutomaticTicketBuyback {
    event AutomaticTicketBuybackExecuted(
        uint256 indexed roundId,
        address indexed buyer,
        address indexed treasuryReceiver,
        uint256 grossWethBudget,
        uint256 specifiedWethIn,
        uint256 inputHookFee,
        uint256 exactWethDebit,
        uint16 slippageBps,
        uint256 minimumNetTokenOut,
        uint256 actualNetTokenOut
    );
}
