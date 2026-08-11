// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {
    ActivationConfiguration,
    BuilderTicketQuote,
    HookConfiguration,
    ImmutableConfiguration,
    ProtocolAccountingView,
    RequestRecord,
    Round,
    RoundConfiguration,
    RoundSettlement,
    TicketBatch
} from "../types/CrottoTypes.sol";

/// @notice Read-only integration and indexing surface for the Crotto Diamond.
interface ICrottoView {
    function immutableConfiguration() external view returns (ImmutableConfiguration memory);

    function currentRoundConfiguration() external view returns (RoundConfiguration memory);

    function currentActivationConfiguration()
        external
        view
        returns (uint64 version, ActivationConfiguration memory configuration);

    function currentHookConfiguration() external view returns (HookConfiguration memory);

    function currentRoundId() external view returns (uint256);

    function round(uint256 roundId) external view returns (Round memory);

    function remainingTickets(uint256 roundId) external view returns (uint256);

    function ticketQuote(uint256 roundId, uint256 quantity)
        external
        view
        returns (uint256 ticketPriceEth, uint256 operationsFeeEth, uint256 totalEth);

    function builderTicketQuote(
        uint256 roundId,
        uint256 quantity,
        address player,
        address builder,
        uint16 builderFeeBps,
        bool redirectTicketRewards
    ) external view returns (BuilderTicketQuote memory quote);

    function ticketBatchCount(uint256 roundId) external view returns (uint256);

    function ticketBatch(uint256 roundId, uint256 index) external view returns (TicketBatch memory);

    function playerTickets(uint256 roundId, address player) external view returns (uint256);

    function rewardTickets(uint256 roundId, address beneficiary) external view returns (uint256);

    function playerRewardClaimed(uint256 roundId, address player) external view returns (bool);

    function playerRewardEntitlement(uint256 roundId, address player) external view returns (uint256);

    function requestRecord(uint256 requestId) external view returns (RequestRecord memory);

    function roundSettlement(uint256 roundId) external view returns (RoundSettlement memory);

    function expiredRoundRefund(uint256 roundId, address buyer)
        external
        view
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth, bool claimed);

    function callerCredit(address account) external view returns (uint256);

    function protocolAccounting() external view returns (ProtocolAccountingView memory);
}
