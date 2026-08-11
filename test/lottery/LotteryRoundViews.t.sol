// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
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
        state.rewardTicketCounts[1][player] = 7;
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
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        LotteryRoundViewHarness viewImplementation = new LotteryRoundViewHarness();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _facetCut(address(cutFacet), _cutSelectors());
        cuts[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        cuts[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        cuts[3] = _facetCut(address(viewImplementation), _viewHarnessSelectors());

        CrottoDiamond diamond = new CrottoDiamond(
            address(this), cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
        views = LotteryRoundViewHarness(address(diamond));
        views.initializeRound(_configuration());
    }

    function test_ViewSelectorsRouteThroughDiamond() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(views));
        bytes4[] memory selectors = _lotteryViewSelectors();
        address implementation = loupe.facetAddress(selectors[0]);
        assertNotEq(implementation, address(0));
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(loupe.facetAddress(selectors[i]), implementation);
        }
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
        assertEq(views.rewardTickets(1, player), 0);
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
        assertEq(views.rewardTickets(1, player), 7);
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
            treasuryShareBps: 1_000,
            buybackShareBps: 1_000,
            operationsReserveCap: 1 ether
        });
    }

    function _facetCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _cutSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = bytes4(keccak256("supportsInterface(bytes4)"));
    }

    function _ownershipSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
    }

    function _viewHarnessSelectors() private pure returns (bytes4[] memory selectors) {
        bytes4[] memory viewSelectors = _lotteryViewSelectors();
        selectors = new bytes4[](13);
        for (uint256 i; i < viewSelectors.length; ++i) {
            selectors[i] = viewSelectors[i];
        }
        selectors[10] = LotteryRoundViewHarness.initializeRound.selector;
        selectors[11] = LotteryRoundViewHarness.seedTicketState.selector;
        selectors[12] = LotteryRoundViewHarness.seedRequest.selector;
    }

    function _lotteryViewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = LotteryViewFacet.currentRoundId.selector;
        selectors[1] = LotteryViewFacet.round.selector;
        selectors[2] = LotteryViewFacet.remainingTickets.selector;
        selectors[3] = LotteryViewFacet.ticketBatchCount.selector;
        selectors[4] = LotteryViewFacet.ticketBatch.selector;
        selectors[5] = LotteryViewFacet.playerTickets.selector;
        selectors[6] = LotteryViewFacet.playerRewardClaimed.selector;
        selectors[7] = LotteryViewFacet.rewardTickets.selector;
        selectors[8] = LotteryViewFacet.playerRewardEntitlement.selector;
        selectors[9] = LotteryViewFacet.requestRecord.selector;
    }
}
