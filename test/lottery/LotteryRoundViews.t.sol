// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {RequestRecord, Round, RoundConfiguration, RoundStatus, TicketBatch} from "../../src/types/CrottoTypes.sol";

contract LotteryRoundViewHarness is LotteryViewFacet {
    error AttemptOutOfBounds(uint256 attempt);

    function initializeRound(RoundConfiguration calldata configuration) external {
        LibLotteryStorage.Layout storage state = LibLotteryStorage.layout();
        state.currentRoundId = 1;
        state.rounds[1].status = RoundStatus.Open;
        state.rounds[1].config = configuration;
    }

    function seedTicketState(address player) external {
        LibLotteryStorage.Layout storage state = LibLotteryStorage.layout();
        state.rounds[1].ticketCount = 11;
        state.ticketBatches[1].push(TicketBatch({endExclusive: 4, buyer: address(0xB0B)}));
        state.ticketBatches[1].push(TicketBatch({endExclusive: 11, buyer: player}));
        state.playerTicketCounts[1][player] = 7;
        state.playerRewardClaimed[1][player] = true;
    }

    function seedRequest(uint256 requestId, uint256 attempt) external {
        if (attempt > type(uint32).max) revert AttemptOutOfBounds(attempt);
        LibLotteryStorage.layout().requests[requestId] =
            RequestRecord({roundId: 1, attempt: uint32(attempt), known: true});
    }
}

contract LotteryRoundViewsTest is Test {
    address private player = makeAddr("player");
    LotteryRoundViewHarness private views;

    function setUp() public {
        views = new LotteryRoundViewHarness();
        views.initializeRound(_configuration());
    }

    function test_InitialRoundExposesCompleteGovernedSnapshot() public view {
        assertEq(views.currentRoundId(), 1);

        Round memory storedRound = views.round(1);
        assertEq(uint8(storedRound.status), uint8(RoundStatus.Open));
        assertEq(storedRound.config.ticketPrice, 1 ether);
        assertEq(storedRound.config.ticketOperationsFee, 0.01 ether);
        assertEq(storedRound.config.playerRewardRate, 10 ether);
        assertEq(storedRound.config.ticketTarget, 100);
        assertEq(storedRound.config.maxVrfCost, 0.5 ether);
        assertEq(storedRound.config.vrfRetryDelay, 10 minutes);
        assertEq(storedRound.config.requestCallerReward, 0.1 ether);
        assertEq(storedRound.config.finalizationCallerReward, 0.1 ether);
        assertEq(storedRound.config.winnerShareBps, 5_000);
        assertEq(storedRound.config.nftShareBps, 3_000);
        assertEq(storedRound.config.buybackShareBps, 1_000);
        assertEq(storedRound.config.treasuryShareBps, 1_000);
        assertEq(storedRound.ticketCount, 0);
        assertEq(views.remainingTickets(1), 100);
        assertEq(views.ticketBatchCount(1), 0);
        assertEq(views.playerTickets(1, player), 0);
        assertFalse(views.playerRewardClaimed(1, player));
        assertEq(views.playerRewardEntitlement(1, player), 0);
    }

    function test_TicketPlayerAndRequestViewsReadIsolatedStorage() public {
        views.seedTicketState(player);
        views.seedRequest(77, 3);

        assertEq(views.remainingTickets(1), 89);
        assertEq(views.ticketBatchCount(1), 2);
        TicketBatch memory first = views.ticketBatch(1, 0);
        TicketBatch memory second = views.ticketBatch(1, 1);
        assertEq(first.endExclusive, 4);
        assertEq(first.buyer, address(0xB0B));
        assertEq(second.endExclusive, 11);
        assertEq(second.buyer, player);
        assertEq(views.playerTickets(1, player), 7);
        assertTrue(views.playerRewardClaimed(1, player));
        assertEq(views.playerRewardEntitlement(1, player), 70 ether);

        RequestRecord memory request = views.requestRecord(77);
        assertEq(request.roundId, 1);
        assertEq(request.attempt, 3);
        assertTrue(request.known);

        RequestRecord memory unknown = views.requestRecord(78);
        assertEq(unknown.roundId, 0);
        assertEq(unknown.attempt, 0);
        assertFalse(unknown.known);
    }

    function test_RevertWhen_RoundDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(LotteryViewFacet.UnknownRound.selector, 0));
        views.round(0);

        vm.expectRevert(abi.encodeWithSelector(LotteryViewFacet.UnknownRound.selector, 2));
        views.remainingTickets(2);
    }

    function test_RevertWhen_TicketBatchIndexDoesNotExist() public {
        views.seedTicketState(player);
        vm.expectRevert(abi.encodeWithSelector(LotteryViewFacet.InvalidTicketBatchIndex.selector, 1, 2, 2));
        views.ticketBatch(1, 2);
    }

    function _configuration() private pure returns (RoundConfiguration memory configuration) {
        configuration = RoundConfiguration({
            ticketPrice: 1 ether,
            ticketOperationsFee: 0.01 ether,
            playerRewardRate: 10 ether,
            ticketTarget: 100,
            maxVrfCost: 0.5 ether,
            vrfRetryDelay: 10 minutes,
            requestCallerReward: 0.1 ether,
            finalizationCallerReward: 0.1 ether,
            winnerShareBps: 5_000,
            nftShareBps: 3_000,
            buybackShareBps: 1_000,
            treasuryShareBps: 1_000
        });
    }
}
