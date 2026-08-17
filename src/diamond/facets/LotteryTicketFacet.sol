// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ICrotto} from "../../interfaces/ICrotto.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibTicketQueue} from "../../libraries/LibTicketQueue.sol";
import {LibWethSolvency} from "../../libraries/LibWethSolvency.sol";
import {LibBuilderFeesStorage} from "../../libraries/storage/LibBuilderFeesStorage.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {LibTreasuryStorage} from "../../libraries/storage/LibTreasuryStorage.sol";
import {BuilderApproval, BuilderTicketQuote, Round, RoundConfiguration, RoundStatus} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Fully funded FIFO ticket-order admission and invalidated-order refunds.
contract LotteryTicketFacet is CrottoFacet {
    error UnknownRound(uint256 roundId);
    error RoundUnavailable(uint256 roundId, RoundStatus status);
    error IncorrectTicketPayment(uint256 expected, uint256 actual);
    error UnexpectedWethDeposit(uint256 expected, uint256 actual);
    error InvalidBuilder(address builder);
    error BuilderFeeBpsExceeded(uint256 requested, uint256 maximum);
    error BuilderFeeNotApproved(address player, address builder, uint256 requested, uint256 approved);
    error InvalidTicketOrderRefundReceiver(address receiver);
    error NativeRefundTransferFailed(address receiver, uint256 amount);
    error UnexpectedNativeRefundDebit(uint256 expected, uint256 actual);

    function buyTickets(uint256 totalTickets, uint256 ticketsPerRound)
        external
        payable
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_TICKET_PURCHASES)
        returns (uint256 orderId)
    {
        return _submitOrder(totalTickets, ticketsPerRound, address(0), 0, false);
    }

    function buyTicketsWithBuilder(
        uint256 totalTickets,
        uint256 ticketsPerRound,
        address builder,
        uint16 builderFeeBps,
        bool redirectTicketRewards
    ) external payable nonReentrant whenNotPaused(CrottoConstants.PAUSE_TICKET_PURCHASES) returns (uint256 orderId) {
        return _submitOrder(totalTickets, ticketsPerRound, builder, builderFeeBps, redirectTicketRewards);
    }

    function ticketQuote(uint256 roundId, uint256 totalTickets, uint256 ticketsPerRound)
        external
        view
        returns (uint256 ticketPriceEth, uint256 operationsFeeEth, uint256 totalEth)
    {
        Round storage storedRound = _quotableRound(roundId, totalTickets, ticketsPerRound);
        return _quote(storedRound.config, totalTickets);
    }

    function builderTicketQuote(
        uint256 roundId,
        uint256 totalTickets,
        uint256 ticketsPerRound,
        address player,
        address builder,
        uint16 builderFeeBps,
        bool redirectTicketRewards
    ) external view returns (BuilderTicketQuote memory quote) {
        Round storage storedRound = _quotableRound(roundId, totalTickets, ticketsPerRound);
        (quote.ticketValueEth, quote.operationsFeeEth, quote.totalEth) = _quote(storedRound.config, totalTickets);
        (quote.rewardBeneficiary, quote.rewardRedirectEffective) =
            _validateBuilder(player, builder, builderFeeBps, redirectTicketRewards);
        quote.builderFeeEth = Math.mulDiv(quote.ticketValueEth, builderFeeBps, CrottoConstants.BPS);
        quote.totalEth += quote.builderFeeEth;
    }

    function claimTicketOrderRefund(uint256 orderId, address wethReceiver, address nativeReceiver)
        external
        nonReentrant
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth)
    {
        (ticketRefundWeth, builderRefundEth) = LibTicketQueue.consumeInvalidatedRefund(orderId, msg.sender);
        if (ticketRefundWeth != 0) _validateReceiver(wethReceiver);
        if (builderRefundEth != 0) _validateReceiver(nativeReceiver);

        if (ticketRefundWeth != 0) {
            LibAssetTransfer.pushExact(
                LibGovernanceStorage.layout().immutableConfiguration.weth, wethReceiver, ticketRefundWeth
            );
        }
        if (builderRefundEth != 0) {
            uint256 balanceBefore = address(this).balance;
            if (!_sendNative(nativeReceiver, builderRefundEth)) {
                revert NativeRefundTransferFailed(nativeReceiver, builderRefundEth);
            }
            uint256 balanceAfter = address(this).balance;
            uint256 debit = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
            if (debit != builderRefundEth) revert UnexpectedNativeRefundDebit(builderRefundEth, debit);
        }

        LibOperationsAccounting.enforceNativeSolvency();
        LibWethSolvency.enforce();
        emit ICrotto.TicketOrderRefundClaimed(
            orderId, msg.sender, wethReceiver, nativeReceiver, ticketRefundWeth, builderRefundEth
        );
    }

    function _submitOrder(
        uint256 totalTickets,
        uint256 ticketsPerRound,
        address builder,
        uint16 builderFeeBps,
        bool redirectTicketRewards
    ) private returns (uint256 orderId) {
        LibTicketQueue.validateQuantities(totalTickets, ticketsPerRound);
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        uint256 roundId = lottery.currentRoundId;
        if (roundId == 0) revert UnknownRound(roundId);
        Round storage currentRound = lottery.rounds[roundId];
        if (currentRound.status == RoundStatus.Finalized || currentRound.status == RoundStatus.Expired) {
            revert RoundUnavailable(roundId, currentRound.status);
        }

        (uint256 ticketValue, uint256 operationsFee, uint256 requiredPayment) =
            _quote(currentRound.config, totalTickets);
        (address rewardBeneficiary, bool rewardRedirectEffective) =
            _validateBuilder(msg.sender, builder, builderFeeBps, redirectTicketRewards);
        uint256 builderFee = Math.mulDiv(ticketValue, builderFeeBps, CrottoConstants.BPS);
        requiredPayment += builderFee;
        if (msg.value != requiredPayment) revert IncorrectTicketPayment(requiredPayment, msg.value);

        uint256 operationsTreasuryWeth = _creditOperations(currentRound.config.operationsReserveCap, operationsFee);
        orderId = LibTicketQueue.submit(
            LibTicketQueue.Submission({
                owner: msg.sender,
                builder: builder,
                rewardBeneficiary: rewardBeneficiary,
                builderFeeBps: builderFeeBps,
                rewardRedirectEffective: rewardRedirectEffective,
                totalTickets: totalTickets,
                ticketsPerRound: ticketsPerRound,
                ticketEscrowWeth: ticketValue,
                operationsFeeEth: operationsFee,
                totalBuilderFee: builderFee
            })
        );

        address weth = LibGovernanceStorage.layout().immutableConfiguration.weth;
        uint256 wethDeposit = ticketValue + operationsTreasuryWeth;
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        IWETH9(weth).deposit{value: wethDeposit}();
        uint256 wethAfter = IERC20(weth).balanceOf(address(this));
        uint256 wethReceived = wethAfter >= wethBefore ? wethAfter - wethBefore : 0;
        if (wethReceived != wethDeposit) revert UnexpectedWethDeposit(wethDeposit, wethReceived);
        LibAssetTransfer.pushExact(weth, LibGovernanceStorage.layout().treasuryReceiver, operationsTreasuryWeth);

        LibTicketQueue.processCurrentRound();
        LibOperationsAccounting.enforceNativeSolvency();
        LibWethSolvency.enforce();
    }

    function _creditOperations(uint256 operationsCap, uint256 operationsFee)
        private
        returns (uint256 operationsTreasuryWeth)
    {
        LibTreasuryStorage.Layout storage treasury = LibTreasuryStorage.layout();
        uint256 reserve = treasury.operationsReserveEth;
        uint256 headroom = reserve < operationsCap ? operationsCap - reserve : 0;
        uint256 reserveContribution = Math.min(operationsFee, headroom);
        treasury.operationsReserveEth = reserve + reserveContribution;
        operationsTreasuryWeth = operationsFee - reserveContribution;
    }

    function _validateBuilder(address player, address builder, uint16 builderFeeBps, bool redirectTicketRewards)
        private
        view
        returns (address rewardBeneficiary, bool rewardRedirectEffective)
    {
        if (builderFeeBps > CrottoConstants.MAX_BUILDER_FEE_BPS) {
            revert BuilderFeeBpsExceeded(builderFeeBps, CrottoConstants.MAX_BUILDER_FEE_BPS);
        }
        if (builder == address(0)) {
            if (builderFeeBps != 0) revert InvalidBuilder(builder);
            return (player, false);
        }

        BuilderApproval memory approval = LibBuilderFeesStorage.layout().approvals[player][builder];
        if (builderFeeBps > approval.maximumFeeBps) {
            revert BuilderFeeNotApproved(player, builder, builderFeeBps, approval.maximumFeeBps);
        }
        rewardRedirectEffective = redirectTicketRewards && approval.mayReceiveTicketRewards;
        if (builderFeeBps != 0 || rewardRedirectEffective) {
            if (LibCrottoValidation.isProtocolAddress(builder, LibGovernanceStorage.layout().immutableConfiguration)) {
                revert InvalidBuilder(builder);
            }
        }
        rewardBeneficiary = rewardRedirectEffective ? builder : player;
    }

    function _quotableRound(uint256 roundId, uint256 totalTickets, uint256 ticketsPerRound)
        private
        view
        returns (Round storage storedRound)
    {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        if (roundId == 0 || roundId != lottery.currentRoundId) revert UnknownRound(roundId);
        LibTicketQueue.validateQuantities(totalTickets, ticketsPerRound);
        storedRound = lottery.rounds[roundId];
        if (storedRound.status == RoundStatus.Finalized || storedRound.status == RoundStatus.Expired) {
            revert RoundUnavailable(roundId, storedRound.status);
        }
    }

    function _quote(RoundConfiguration storage configuration, uint256 totalTickets)
        private
        view
        returns (uint256 ticketValue, uint256 operationsFee, uint256 requiredPayment)
    {
        ticketValue = configuration.ticketPrice * totalTickets;
        operationsFee = configuration.ticketOperationsFee * totalTickets;
        requiredPayment = ticketValue + operationsFee;
    }

    function _validateReceiver(address receiver) private view {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidTicketOrderRefundReceiver(receiver);
    }

    function _sendNative(address receiver, uint256 amount) private returns (bool success) {
        assembly ("memory-safe") {
            success := call(gas(), receiver, amount, 0, 0, 0, 0)
        }
    }
}
