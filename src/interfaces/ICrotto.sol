// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {CallerAction, IgnoredFulfillmentReason} from "../types/CrottoTypes.sol";

/// @notice Permissionless lottery lifecycle and pull-claim surface of the Crotto Diamond.
interface ICrotto {
    event RoundInitialized(uint256 indexed roundId);
    event TicketsPurchased(
        uint256 indexed roundId,
        address indexed buyer,
        uint256 quantity,
        uint256 startTicket,
        uint256 endTicketExclusive,
        uint256 ticketPriceWeth,
        uint256 operationsFeeEth,
        uint256 buybackWeth,
        uint256 totalTicketsSold
    );
    event RoundClosed(uint256 indexed roundId, uint256 ticketCount);
    event RandomnessRequested(
        uint256 indexed roundId, uint256 indexed requestId, uint32 attempt, address indexed caller
    );
    event RandomnessRetried(uint256 indexed roundId, uint256 indexed requestId, uint32 attempt, address indexed caller);
    event RandomnessAccepted(uint256 indexed roundId, uint256 indexed requestId, uint256 randomWord);
    event RandomnessIgnored(uint256 indexed requestId, uint256 indexed roundId, IgnoredFulfillmentReason reason);
    event LotteryFinalized(
        uint256 indexed roundId,
        uint256 winningTicket,
        address indexed winner,
        uint256 winnerPoolWeth,
        uint256 playerTokenLiability
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

    function buyTickets(uint256 quantity) external payable;

    function fundOperationsReserve() external payable;

    function requestRandomness(uint256 roundId) external returns (uint256 requestId);

    function retryRandomness(uint256 roundId) external returns (uint256 requestId);

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;

    function finalizeLottery(uint256 roundId) external;

    function claimWinnings(uint256 roundId, address receiver) external returns (uint256 amount);

    function claimPlayerRewards(uint256 roundId, address receiver) external returns (uint256 amount);

    function claimCallerRewards(address receiver) external returns (uint256 amount);
}
