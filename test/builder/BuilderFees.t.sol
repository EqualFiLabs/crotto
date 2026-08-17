// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BuilderFeesFacet} from "../../src/diamond/facets/BuilderFeesFacet.sol";
import {LotteryTicketFacet} from "../../src/diamond/facets/LotteryTicketFacet.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {BuilderApproval, BuilderTicketQuote, RoundSettlement} from "../../src/types/CrottoTypes.sol";
import {AutomaticTicketBuybackFixture} from "../liquidity/AutomaticTicketBuyback.t.sol";

contract RejectNativeBuilderReceiver {
    receive() external payable {
        revert("native rejected");
    }
}

contract BuilderFeesTest is AutomaticTicketBuybackFixture {
    address private builder = makeAddr("builder");
    address private secondBuilder = makeAddr("secondBuilder");
    address private receiver = makeAddr("builderReceiver");

    function setUp() public {
        _deployProtocol(true);
    }

    function test_PlayerControlsIndependentFeeAndRewardPermissions() public {
        vm.prank(player);
        builders.approveBuilder(builder, 50, true);
        BuilderApproval memory approval = builders.builderApproval(player, builder);
        assertEq(approval.maximumFeeBps, 50);
        assertTrue(approval.mayReceiveTicketRewards);

        vm.prank(player);
        builders.approveBuilder(builder, 15, false);
        approval = builders.builderApproval(player, builder);
        assertEq(approval.maximumFeeBps, 15);
        assertFalse(approval.mayReceiveTicketRewards);

        vm.prank(player);
        builders.approveBuilder(secondBuilder, 0, true);
        BuilderApproval memory secondApproval = builders.builderApproval(player, secondBuilder);
        assertEq(secondApproval.maximumFeeBps, 0);
        assertTrue(secondApproval.mayReceiveTicketRewards);

        vm.prank(player);
        builders.revokeBuilder(builder);
        approval = builders.builderApproval(player, builder);
        assertEq(approval.maximumFeeBps, 0);
        assertFalse(approval.mayReceiveTicketRewards);
    }

    function test_RevertWhen_ApprovalExceedsPermanentCeilingOrIsEmpty() public {
        assertEq(builders.MAX_BUILDER_FEE_BPS(), 50);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BuilderFeesFacet.BuilderFeeBpsExceeded.selector, 51, 50));
        builders.approveBuilder(builder, 51, false);

        vm.prank(player);
        vm.expectRevert(BuilderFeesFacet.EmptyBuilderApproval.selector);
        builders.approveBuilder(builder, 0, false);
    }

    function test_StateMutatingBuilderFunctionsRejectDirectFacetCalls() public {
        BuilderFeesFacet implementation = new BuilderFeesFacet();
        vm.expectRevert(BuilderFeesFacet.DirectFacetCall.selector);
        implementation.approveBuilder(builder, 1, false);
        vm.expectRevert(BuilderFeesFacet.DirectFacetCall.selector);
        implementation.revokeBuilder(builder);
        vm.expectRevert(BuilderFeesFacet.DirectFacetCall.selector);
        implementation.claimBuilderFees(receiver);
    }

    function test_BuilderPurchaseAccruesOnlySurchargeAndPreservesProtocolEconomics() public {
        _buyTickets(1);
        RoundSettlement memory beforeSettlement = views.roundSettlement(1);
        uint256 bootstrapBefore = pol.bootstrapPolWeth();
        uint256 treasuryWethBefore = weth.balanceOf(treasury);
        uint256 diamondWethBefore = weth.balanceOf(address(diamond));

        vm.prank(player);
        builders.approveBuilder(builder, 50, false);
        BuilderTicketQuote memory quote =
            LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 1, 1, player, builder, 50, false);
        assertEq(quote.ticketValueEth, TICKET_PRICE);
        assertEq(quote.operationsFeeEth, OPERATIONS_FEE);
        assertEq(quote.builderFeeEth, 0.005 ether);
        assertEq(quote.totalEth, TICKET_PRICE + OPERATIONS_FEE + 0.005 ether);
        assertEq(quote.rewardBeneficiary, player);
        assertFalse(quote.rewardRedirectEffective);

        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(1, 1, builder, 50, false);

        RoundSettlement memory afterSettlement = views.roundSettlement(1);
        assertEq(afterSettlement.winnerWeth - beforeSettlement.winnerWeth, 0.5 ether);
        assertEq(afterSettlement.bootstrapPolWeth - beforeSettlement.bootstrapPolWeth, 0.4 ether);
        assertEq(pol.bootstrapPolWeth() - bootstrapBefore, 0);
        assertEq(weth.balanceOf(treasury) - treasuryWethBefore, 0);
        assertEq(weth.balanceOf(address(diamond)) - diamondWethBefore, 1 ether);
        assertEq(builders.builderCredit(builder), 0);
        assertEq(builders.provisionalBuilderCredit(1, builder), 0.005 ether);
        assertEq(builders.totalBuilderFeeLiability(), 0.005 ether);
        assertEq(address(diamond).balance, 2 * OPERATIONS_FEE + 0.005 ether);
        assertEq(views.playerTickets(1, player), 2);
        assertEq(views.rewardTickets(1, player), 2);
    }

    function test_BuilderFeeStaysNativeWhileOperationsOverflowRoutesAsTreasuryWeth() public {
        _buyTickets(50);
        assertEq(address(diamond).balance, 0.5 ether);

        vm.prank(player);
        builders.approveBuilder(builder, 50, false);
        BuilderTicketQuote memory quote =
            LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 1, 1, player, builder, 50, false);
        uint256 treasuryWethBefore = weth.balanceOf(treasury);
        uint256 diamondWethBefore = weth.balanceOf(address(diamond));

        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(1, 1, builder, 50, false);

        assertEq(weth.balanceOf(treasury) - treasuryWethBefore, 0.01 ether);
        assertEq(weth.balanceOf(address(diamond)) - diamondWethBefore, 1 ether);
        assertEq(address(diamond).balance, 0.505 ether);
        assertEq(builders.provisionalBuilderCredit(1, builder), 0.005 ether);
        assertEq(builders.totalBuilderFeeLiability(), 0.005 ether);
    }

    function test_UnauthorizedRewardRedirectFallsBackWithoutBlockingApprovedFee() public {
        vm.prank(player);
        builders.approveBuilder(builder, 25, false);
        BuilderTicketQuote memory quote =
            LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 2, 2, player, builder, 20, true);
        assertEq(quote.rewardBeneficiary, player);
        assertFalse(quote.rewardRedirectEffective);

        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(2, 2, builder, 20, true);
        assertEq(views.playerTickets(1, player), 2);
        assertEq(views.rewardTickets(1, player), 2);
        assertEq(views.rewardTickets(1, builder), 0);
        assertEq(builders.provisionalBuilderCredit(1, builder), 0.004 ether);
    }

    function test_RevocationDoesNotChangeHistoricalRewardAssignment() public {
        vm.startPrank(player);
        builders.approveBuilder(builder, 0, true);
        lottery.buyTicketsWithBuilder{value: (TICKET_PRICE + OPERATIONS_FEE) * 2}(2, 2, builder, 0, true);
        builders.revokeBuilder(builder);
        vm.stopPrank();

        assertEq(views.rewardTickets(1, builder), 2);
        assertEq(views.rewardTickets(1, player), 0);
        BuilderTicketQuote memory nextQuote =
            LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 1, 1, player, builder, 0, true);
        assertEq(nextQuote.rewardBeneficiary, player);
        assertFalse(nextQuote.rewardRedirectEffective);
    }

    function test_RewardRedirectDoesNotRequireOrCreateBuilderFee() public {
        vm.prank(player);
        builders.approveBuilder(builder, 0, true);
        BuilderTicketQuote memory quote =
            LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 3, 3, player, builder, 0, true);
        assertEq(quote.builderFeeEth, 0);
        assertEq(quote.totalEth, (TICKET_PRICE + OPERATIONS_FEE) * 3);
        assertEq(quote.rewardBeneficiary, builder);
        assertTrue(quote.rewardRedirectEffective);

        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(3, 3, builder, 0, true);
        assertEq(views.playerTickets(1, player), 3);
        assertEq(views.rewardTickets(1, player), 0);
        assertEq(views.rewardTickets(1, builder), 3);
        assertEq(builders.builderCredit(builder), 0);
    }

    function test_ZeroBuilderPreservesCanonicalPurchaseAndRejectsNonzeroFee() public {
        BuilderTicketQuote memory quote =
            LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 1, 1, player, address(0), 0, true);
        assertEq(quote.builderFeeEth, 0);
        assertEq(quote.rewardBeneficiary, player);
        assertFalse(quote.rewardRedirectEffective);
        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(1, 1, address(0), 0, true);
        assertEq(views.playerTickets(1, player), 1);
        assertEq(views.rewardTickets(1, player), 1);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.InvalidBuilder.selector, address(0)));
        lottery.buyTicketsWithBuilder{value: TICKET_PRICE + OPERATIONS_FEE}(1, 1, address(0), 1, false);
    }

    function test_RevertWhen_FeeExceedsApprovalOrProtocolCeiling() public {
        vm.prank(player);
        builders.approveBuilder(builder, 20, false);

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryTicketFacet.BuilderFeeNotApproved.selector, player, builder, 21, 20)
        );
        lottery.buyTicketsWithBuilder{value: TICKET_PRICE + OPERATIONS_FEE}(1, 1, builder, 21, false);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.BuilderFeeBpsExceeded.selector, 51, 50));
        lottery.buyTicketsWithBuilder{value: TICKET_PRICE + OPERATIONS_FEE}(1, 1, builder, 51, false);

        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.BuilderFeeBpsExceeded.selector, type(uint16).max, 50));
        LotteryTicketFacet(address(diamond)).builderTicketQuote(1, 1, 1, player, builder, type(uint16).max, false);
        assertEq(views.round(1).ticketCount, 0);
        assertEq(builders.builderCredit(builder), 0);
    }

    function test_RevocationImmediatelyDisablesNonzeroFees() public {
        vm.startPrank(player);
        builders.approveBuilder(builder, 50, true);
        builders.revokeBuilder(builder);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryTicketFacet.BuilderFeeNotApproved.selector, player, builder, 1, 0)
        );
        lottery.buyTicketsWithBuilder{value: TICKET_PRICE + OPERATIONS_FEE}(1, 1, builder, 1, true);
        vm.stopPrank();
    }

    function test_ExactPaymentRejectsBuilderUnderpaymentAndOverpaymentAtomically() public {
        vm.prank(player);
        builders.approveBuilder(builder, 50, false);
        uint256 expected = TICKET_PRICE + OPERATIONS_FEE + 0.005 ether;

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryTicketFacet.IncorrectTicketPayment.selector, expected, expected - 1)
        );
        lottery.buyTicketsWithBuilder{value: expected - 1}(1, 1, builder, 50, false);

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryTicketFacet.IncorrectTicketPayment.selector, expected, expected + 1)
        );
        lottery.buyTicketsWithBuilder{value: expected + 1}(1, 1, builder, 50, false);

        assertEq(views.round(1).ticketCount, 0);
        assertEq(builders.builderCredit(builder), 0);
        assertEq(builders.totalBuilderFeeLiability(), 0);
    }

    function test_SelfBuilderReceivesExactlyItsOwnAdditionalPayment() public {
        vm.prank(player);
        builders.approveBuilder(player, 50, true);
        uint256 balanceBefore = player.balance;
        uint256 total = TICKET_PRICE + OPERATIONS_FEE + 0.005 ether;
        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: total}(1, 1, player, 50, true);

        assertEq(balanceBefore - player.balance, total);
        assertEq(builders.provisionalBuilderCredit(1, player), 0.005 ether);
        assertEq(views.playerTickets(1, player), 1);
        assertEq(views.rewardTickets(1, player), 1);
    }

    function test_MultipleUsersAccumulateOneBuilderCreditAndClaimExactly() public {
        address secondPlayer = makeAddr("secondPlayer");
        vm.deal(secondPlayer, 10 ether);
        _approveAndBuy(player, builder, 50, 1, false);
        _approveAndBuy(secondPlayer, builder, 50, 2, false);
        uint256 expectedCredit = 0.015 ether;
        assertEq(builders.provisionalBuilderCredit(1, builder), expectedCredit);
        assertEq(builders.totalBuilderFeeLiability(), expectedCredit);

        _finalizeCurrentRound();
        vm.prank(builder);
        assertEq(builders.settleBuilderFees(1), expectedCredit);

        uint256 receiverBefore = receiver.balance;
        uint256 diamondBefore = address(diamond).balance;
        vm.prank(builder);
        uint256 claimed = builders.claimBuilderFees(receiver);
        assertEq(claimed, expectedCredit);
        assertEq(receiver.balance - receiverBefore, expectedCredit);
        assertEq(diamondBefore - address(diamond).balance, expectedCredit);
        assertEq(builders.builderCredit(builder), 0);
        assertEq(builders.totalBuilderFeeLiability(), 0);

        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(BuilderFeesFacet.BuilderFeeUnavailable.selector, builder));
        builders.claimBuilderFees(receiver);
    }

    function test_FailedClaimRestoresCreditLiabilityAndDiamondBalance() public {
        _approveAndBuy(player, builder, 50, 1, false);
        _finalizeCurrentRound();
        vm.prank(builder);
        builders.settleBuilderFees(1);
        RejectNativeBuilderReceiver rejecting = new RejectNativeBuilderReceiver();
        uint256 diamondBefore = address(diamond).balance;

        vm.prank(builder);
        vm.expectRevert(
            abi.encodeWithSelector(BuilderFeesFacet.NativeTransferFailed.selector, address(rejecting), 0.005 ether)
        );
        builders.claimBuilderFees(address(rejecting));

        assertEq(builders.builderCredit(builder), 0.005 ether);
        assertEq(builders.totalBuilderFeeLiability(), 0.005 ether);
        assertEq(address(diamond).balance, diamondBefore);
    }

    function test_ApprovalAndClaimsRemainAvailableWhileTicketPurchasesArePaused() public {
        governance.pauseActions(CrottoConstants.PAUSE_TICKET_PURCHASES);
        vm.prank(player);
        builders.approveBuilder(builder, 50, true);
        BuilderApproval memory approval = builders.builderApproval(player, builder);
        assertEq(approval.maximumFeeBps, 50);

        vm.prank(player);
        vm.expectRevert();
        lottery.buyTicketsWithBuilder{value: TICKET_PRICE + OPERATIONS_FEE}(1, 1, builder, 0, true);
    }

    function test_RevertWhen_ProtocolAddressWouldReceiveFeeOrEffectiveRedirect() public {
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BuilderFeesFacet.InvalidBuilder.selector, address(token)));
        builders.approveBuilder(address(token), 1, false);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(BuilderFeesFacet.InvalidBuilderFeeReceiver.selector, address(diamond)));
        builders.claimBuilderFees(address(diamond));
    }

    function test_PostPolPurchaseDoesNotDependOnBuybackExecution() public {
        _bootstrapPOL();
        vm.prank(player);
        builders.approveBuilder(builder, 50, false);
        uint256 roundId = views.currentRoundId();
        uint256 ticketCountBefore = views.round(roundId).ticketCount;
        uint256 total = TICKET_PRICE * 25 + OPERATIONS_FEE * 25 + 0.125 ether;

        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: total}(25, 25, builder, 50, false);

        assertEq(views.round(roundId).ticketCount, ticketCountBefore + 25);
        assertEq(builders.builderCredit(builder), 0);
        assertEq(builders.provisionalBuilderCredit(roundId, builder), 0.125 ether);
        assertEq(builders.totalBuilderFeeLiability(), 0.125 ether);
    }

    function test_WethFailureRollsBackBuilderAccrualAndRewardAssignment() public {
        vm.prank(player);
        builders.approveBuilder(builder, 50, true);
        vm.mockCall(address(weth), abi.encodeWithSignature("deposit()"), bytes(""));
        uint256 total = TICKET_PRICE + OPERATIONS_FEE + 0.005 ether;

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.UnexpectedWethDeposit.selector, TICKET_PRICE, 0));
        lottery.buyTicketsWithBuilder{value: total}(1, 1, builder, 50, true);

        assertEq(views.round(1).ticketCount, 0);
        assertEq(views.rewardTickets(1, builder), 0);
        assertEq(builders.builderCredit(builder), 0);
        assertEq(builders.totalBuilderFeeLiability(), 0);
        assertEq(address(diamond).balance, 0);
    }

    function test_PurchaseNeverCallsBuilder() public {
        RejectNativeBuilderReceiver rejectingBuilder = new RejectNativeBuilderReceiver();
        vm.prank(player);
        builders.approveBuilder(address(rejectingBuilder), 50, true);
        uint256 total = TICKET_PRICE + OPERATIONS_FEE + 0.005 ether;

        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: total}(1, 1, address(rejectingBuilder), 50, true);

        assertEq(builders.provisionalBuilderCredit(1, address(rejectingBuilder)), 0.005 ether);
        assertEq(views.rewardTickets(1, address(rejectingBuilder)), 1);
    }

    function test_RedirectedRewardIsClaimedByBuilderWithoutChangingWinnerOwnership() public {
        vm.prank(player);
        builders.approveBuilder(builder, 0, true);
        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: TICKET_PRICE + OPERATIONS_FEE}(1, 1, builder, 0, true);
        _buyTickets(TICKET_TARGET - 1);

        vm.prank(receiver);
        uint256 requestId = lottery.requestRandomness(1);
        vrfWrapper.fulfill(requestId, 0);
        vm.prank(receiver);
        lottery.finalizeLottery(1);

        assertEq(views.round(1).winner, player);
        assertEq(views.playerTickets(1, player), TICKET_TARGET);
        assertEq(views.rewardTickets(1, builder), 1);
        assertEq(views.rewardTickets(1, player), TICKET_TARGET - 1);
        vm.prank(builder);
        assertEq(lottery.claimPlayerRewards(1, builder), 100 ether);
        assertEq(token.balanceOf(builder), 100 ether);
    }

    function testFuzz_ApprovedFeeUsesFloorRoundingAndNeverSubsidizesBuilder(uint256 quantity, uint256 feeBps) public {
        quantity = bound(quantity, 1, TICKET_TARGET);
        feeBps = bound(feeBps, 0, 50);
        uint16 boundedFeeBps = SafeCast.toUint16(feeBps);
        vm.prank(player);
        builders.approveBuilder(builder, boundedFeeBps, true);
        BuilderTicketQuote memory quote = LotteryTicketFacet(address(diamond))
            .builderTicketQuote(1, quantity, quantity, player, builder, boundedFeeBps, false);
        uint256 expectedFee = Math.mulDiv(TICKET_PRICE * quantity, feeBps, CrottoConstants.BPS);
        assertEq(quote.builderFeeEth, expectedFee);

        uint256 playerBefore = player.balance;
        vm.prank(player);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(quantity, quantity, builder, boundedFeeBps, false);
        assertEq(playerBefore - player.balance, quote.totalEth);
        assertEq(builders.provisionalBuilderCredit(1, builder), expectedFee);
        assertEq(views.rewardTickets(1, player), quantity);
    }

    function _approveAndBuy(address buyer, address targetBuilder, uint16 bps, uint256 quantity, bool redirect) private {
        vm.prank(buyer);
        builders.approveBuilder(targetBuilder, bps, redirect);
        BuilderTicketQuote memory quote = LotteryTicketFacet(address(diamond))
            .builderTicketQuote(1, quantity, quantity, buyer, targetBuilder, bps, redirect);
        vm.prank(buyer);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(quantity, quantity, targetBuilder, bps, redirect);
    }

    function _finalizeCurrentRound() private {
        uint256 remaining = TICKET_TARGET - views.round(1).ticketCount;
        if (remaining != 0) _buyTickets(remaining);
        vm.prank(receiver);
        uint256 requestId = lottery.requestRandomness(1);
        vrfWrapper.fulfill(requestId, 0);
        vm.prank(receiver);
        lottery.finalizeLottery(1);
    }
}
