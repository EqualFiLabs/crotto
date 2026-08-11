// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Indexer surface for permissionless deferred canonical TOKEN purchases.
interface IAutomaticTicketBuyback {
    event PendingBuybackExecuted(
        address indexed caller,
        address indexed treasuryReceiver,
        uint256 indexed sequence,
        uint256 consumedWeth,
        uint256 callerTipWeth,
        uint256 specifiedWethIn,
        uint256 inputHookFee,
        uint256 exactWethDebit,
        uint256 actualNetTokenOut
    );

    function executePendingBuyback() external returns (uint256 consumedWeth, uint256 actualNetTokenOut);
}
