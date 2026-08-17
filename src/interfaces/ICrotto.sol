// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {CallerAction, IgnoredFulfillmentReason} from "../types/CrottoTypes.sol";

/// @notice Permissionless lottery lifecycle and pull-claim surface of the Crotto Diamond.
interface ICrotto {
    event RoundInitialized(uint256 indexed roundId);
    event TicketOrderSubmitted(
        uint256 indexed orderId,
        address indexed owner,
        uint256 indexed generation,
        bytes32 configurationHash,
        uint256 totalTickets,
        uint256 ticketsPerRound,
        uint256 ticketEscrowWeth,
        uint256 operationsFeeEth,
        uint256 builderEscrowEth
    );
    event TicketOrderAllocated(
        uint256 indexed orderId,
        uint256 indexed roundId,
        address indexed owner,
        uint256 quantity,
        uint256 remainingTickets,
        uint256 startTicket,
        uint256 endTicketExclusive,
        uint256 ticketValueWeth,
        uint256 builderFeeEth
    );
    event TicketQueueGenerationInvalidated(
        uint256 indexed generation,
        bytes32 indexed configurationHash,
        uint256 ticketRefundWeth,
        uint256 builderRefundEth
    );
    event TicketOrderRefundClaimed(
        uint256 indexed orderId,
        address indexed owner,
        address indexed wethReceiver,
        address nativeReceiver,
        uint256 ticketRefundWeth,
        uint256 builderRefundEth
    );
    event RoundClosed(uint256 indexed roundId, uint256 ticketCount);
    event RandomnessRequested(
        uint256 indexed roundId, uint256 indexed requestId, uint32 attempt, address indexed caller
    );
    event RandomnessAccepted(uint256 indexed roundId, uint256 indexed requestId, uint256 randomWord);
    event RandomnessIgnored(uint256 indexed requestId, uint256 indexed roundId, IgnoredFulfillmentReason reason);
    event LotteryFinalized(
        uint256 indexed roundId,
        uint256 winningTicket,
        address indexed winner,
        uint256 winnerPoolWeth,
        uint256 playerTokenLiability
    );
    event LotteryExpired(
        uint256 indexed roundId, uint256 ticketRefundWeth, uint256 builderRefundEth, address indexed caller
    );
    event ExpiredRoundRefundClaimed(
        uint256 indexed roundId,
        address indexed buyer,
        address indexed wethReceiver,
        address nativeReceiver,
        uint256 ticketRefundWeth,
        uint256 builderRefundEth
    );
    event WinningsClaimed(uint256 indexed roundId, address indexed winner, address indexed receiver, uint256 amount);
    event PlayerRewardsClaimed(
        uint256 indexed roundId, address indexed player, address indexed receiver, uint256 amount
    );
    event CallerRewardCredited(
        address indexed caller, CallerAction indexed action, uint256 indexed roundId, uint256 amount
    );
    event CallerRewardClaimed(address indexed caller, address indexed receiver, uint256 amount);
    event OperationsReserveFunded(address indexed contributor, uint256 amount);

    function buyTickets(uint256 totalTickets, uint256 ticketsPerRound) external payable returns (uint256 orderId);

    function buyTicketsWithBuilder(
        uint256 totalTickets,
        uint256 ticketsPerRound,
        address builder,
        uint16 builderFeeBps,
        bool redirectTicketRewards
    ) external payable returns (uint256 orderId);

    function claimTicketOrderRefund(uint256 orderId, address wethReceiver, address nativeReceiver)
        external
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth);

    function fundOperationsReserve() external payable;

    function requestRandomness(uint256 roundId) external returns (uint256 requestId);

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;

    function finalizeLottery(uint256 roundId) external;

    function expireLottery(uint256 roundId) external;

    function claimExpiredRoundRefund(uint256 roundId, address wethReceiver, address nativeReceiver)
        external
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth);

    function claimWinnings(uint256 roundId, address receiver) external returns (uint256 amount);

    function claimPlayerRewards(uint256 roundId, address receiver) external returns (uint256 amount);

    function claimCallerRewards(address receiver) external returns (uint256 amount);
}
