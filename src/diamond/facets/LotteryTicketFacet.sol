// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ICrotto} from "../../interfaces/ICrotto.sol";
import {ICrottoBuilderFees} from "../../interfaces/ICrottoBuilderFees.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibProvisionalRewardAccounting} from "../../libraries/LibProvisionalRewardAccounting.sol";
import {LibWethSolvency} from "../../libraries/LibWethSolvency.sol";
import {LibBuilderFeesStorage} from "../../libraries/storage/LibBuilderFeesStorage.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "../../libraries/storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {LibRoundSettlementStorage} from "../../libraries/storage/LibRoundSettlementStorage.sol";
import {LibTreasuryStorage} from "../../libraries/storage/LibTreasuryStorage.sol";
import {
    BuilderApproval,
    BuilderTicketQuote,
    Round,
    RoundConfiguration,
    RoundSettlement,
    RoundStatus,
    TicketBatch
} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Exact native-ETH ticket purchases with isolated Builder, WETH, and Operations accounting.
contract LotteryTicketFacet is CrottoFacet {
    error UnknownRound(uint256 roundId);
    error RoundNotOpen(uint256 roundId, RoundStatus status);
    error InvalidTicketQuantity();
    error TicketQuantityExceedsRemaining(uint256 requested, uint256 remaining);
    error IncorrectTicketPayment(uint256 expected, uint256 actual);
    error UnexpectedWethDeposit(uint256 expected, uint256 actual);
    error InvalidBuilder(address builder);
    error BuilderFeeBpsExceeded(uint256 requested, uint256 maximum);
    error BuilderFeeNotApproved(address player, address builder, uint256 requested, uint256 approved);

    struct PurchaseContext {
        uint256 roundId;
        uint256 startTicket;
        uint256 endTicketExclusive;
        uint256 ticketValue;
        uint256 operationsContribution;
        uint256 operationsTreasuryWeth;
        uint256 builderFee;
        address rewardBeneficiary;
        bool rewardRedirectEffective;
    }

    function buyTickets(uint256 quantity)
        external
        payable
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_TICKET_PURCHASES)
    {
        _buyTickets(quantity, address(0), 0, false);
    }

    function buyTicketsWithBuilder(uint256 quantity, address builder, uint16 builderFeeBps, bool redirectTicketRewards)
        external
        payable
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_TICKET_PURCHASES)
    {
        _buyTickets(quantity, builder, builderFeeBps, redirectTicketRewards);
    }

    function ticketQuote(uint256 roundId, uint256 quantity)
        external
        view
        returns (uint256 ticketPriceEth, uint256 operationsFeeEth, uint256 totalEth)
    {
        Round storage storedRound = _quotableRound(roundId, quantity);
        return _quote(storedRound.config, quantity);
    }

    function builderTicketQuote(
        uint256 roundId,
        uint256 quantity,
        address player,
        address builder,
        uint16 builderFeeBps,
        bool redirectTicketRewards
    ) external view returns (BuilderTicketQuote memory quote) {
        Round storage storedRound = _quotableRound(roundId, quantity);
        (quote.ticketValueEth, quote.operationsFeeEth, quote.totalEth) = _quote(storedRound.config, quantity);
        (quote.rewardBeneficiary, quote.rewardRedirectEffective) =
            _validateBuilder(player, builder, builderFeeBps, redirectTicketRewards);
        quote.builderFeeEth = Math.mulDiv(quote.ticketValueEth, builderFeeBps, CrottoConstants.BPS);
        quote.totalEth += quote.builderFeeEth;
    }

    function _buyTickets(uint256 quantity, address builder, uint16 builderFeeBps, bool redirectTicketRewards) private {
        if (quantity == 0) revert InvalidTicketQuantity();

        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        PurchaseContext memory purchase;
        purchase.roundId = lottery.currentRoundId;
        if (purchase.roundId == 0) revert UnknownRound(purchase.roundId);
        Round storage currentRound = lottery.rounds[purchase.roundId];
        if (currentRound.status != RoundStatus.Open) {
            revert RoundNotOpen(purchase.roundId, currentRound.status);
        }

        purchase.startTicket = currentRound.ticketCount;
        uint256 remaining = currentRound.config.ticketTarget - purchase.startTicket;
        if (quantity > remaining) revert TicketQuantityExceedsRemaining(quantity, remaining);

        uint256 requiredPayment;
        (purchase.ticketValue, purchase.operationsContribution, requiredPayment) = _quote(currentRound.config, quantity);
        (purchase.rewardBeneficiary, purchase.rewardRedirectEffective) =
            _validateBuilder(msg.sender, builder, builderFeeBps, redirectTicketRewards);
        purchase.builderFee = Math.mulDiv(purchase.ticketValue, builderFeeBps, CrottoConstants.BPS);
        requiredPayment += purchase.builderFee;
        if (msg.value != requiredPayment) revert IncorrectTicketPayment(requiredPayment, msg.value);

        purchase.endTicketExclusive = purchase.startTicket + quantity;
        currentRound.ticketCount = purchase.endTicketExclusive;
        lottery.ticketBatches[purchase.roundId].push(
            TicketBatch({endExclusive: purchase.endTicketExclusive, buyer: msg.sender})
        );
        lottery.playerTicketCounts[purchase.roundId][msg.sender] += quantity;
        lottery.rewardTicketCounts[purchase.roundId][purchase.rewardBeneficiary] += quantity;
        _accrueBuilderFee(purchase, builder, builderFeeBps, quantity);

        (uint256 buybackAmount, uint256 operationsTreasuryWeth, bool polInitialized) =
            _routeTicketValue(currentRound, purchase.ticketValue, purchase.operationsContribution);
        purchase.operationsTreasuryWeth = operationsTreasuryWeth;

        if (purchase.endTicketExclusive == currentRound.config.ticketTarget) {
            currentRound.status = RoundStatus.Closed;
            currentRound.closedAtBlock = uint64(block.number);
        }

        address weth = LibGovernanceStorage.layout().immutableConfiguration.weth;
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        uint256 wethDeposit = purchase.ticketValue + purchase.operationsTreasuryWeth;
        IWETH9(weth).deposit{value: wethDeposit}();
        uint256 wethAfter = IERC20(weth).balanceOf(address(this));
        uint256 wethReceived = wethAfter >= wethBefore ? wethAfter - wethBefore : 0;
        if (wethReceived != wethDeposit) revert UnexpectedWethDeposit(wethDeposit, wethReceived);

        LibAssetTransfer.pushExact(
            weth, LibGovernanceStorage.layout().treasuryReceiver, purchase.operationsTreasuryWeth
        );

        LibOperationsAccounting.enforceNativeSolvency();
        LibWethSolvency.enforce();
        emit ICrotto.TicketsPurchased(
            purchase.roundId,
            msg.sender,
            quantity,
            purchase.startTicket,
            purchase.endTicketExclusive,
            purchase.ticketValue,
            purchase.operationsContribution,
            purchase.operationsTreasuryWeth,
            buybackAmount,
            !polInitialized
        );
        if (currentRound.status == RoundStatus.Closed) {
            emit ICrotto.RoundClosed(purchase.roundId, purchase.endTicketExclusive);
        }
    }

    function _routeTicketValue(Round storage currentRound, uint256 ticketValue, uint256 operationsContribution)
        private
        returns (uint256 buybackAmount, uint256 operationsTreasuryWeth, bool polInitialized)
    {
        uint256 winnerAmount = Math.mulDiv(ticketValue, currentRound.config.winnerShareBps, CrottoConstants.BPS);
        uint256 nftAmount = Math.mulDiv(ticketValue, currentRound.config.nftShareBps, CrottoConstants.BPS);
        buybackAmount = Math.mulDiv(ticketValue, currentRound.config.buybackShareBps, CrottoConstants.BPS);
        uint256 treasuryAmount = ticketValue - winnerAmount - nftAmount - buybackAmount;
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        RoundSettlement storage settlement = settlements.rounds[LibLotteryStorage.layout().currentRoundId];
        settlement.ticketEscrowWeth += ticketValue;
        settlement.winnerWeth += winnerAmount;
        settlements.activeTicketEscrowWeth += ticketValue;
        LibTreasuryStorage.Layout storage treasury = LibTreasuryStorage.layout();
        uint256 operationsReserve = treasury.operationsReserveEth;
        uint256 operationsCap = currentRound.config.operationsReserveCap;
        uint256 operationsHeadroom = operationsReserve < operationsCap ? operationsCap - operationsReserve : 0;
        uint256 reserveContribution = Math.min(operationsContribution, operationsHeadroom);
        operationsTreasuryWeth = operationsContribution - reserveContribution;
        treasury.operationsReserveEth = operationsReserve + reserveContribution;
        bool activeRewardNfts = LibRewardsStorage.layout().totalActiveWeight != 0;
        polInitialized = LibPOLStorage.layout().initialized;
        if (activeRewardNfts) {
            LibProvisionalRewardAccounting.accrue(
                LibLotteryStorage.layout().currentRoundId, nftAmount, LibRewardsStorage.layout().totalActiveWeight
            );
        } else if (!polInitialized) {
            settlement.bootstrapPolWeth += nftAmount;
        } else {
            treasuryAmount += nftAmount;
        }
        if (!polInitialized) settlement.bootstrapPolWeth += buybackAmount;
        else settlement.buybackWeth += buybackAmount;
        settlement.treasuryWeth += treasuryAmount;
    }

    function _accrueBuilderFee(PurchaseContext memory purchase, address builder, uint16 builderFeeBps, uint256 quantity)
        private
    {
        if (purchase.builderFee != 0) {
            LibBuilderFeesStorage.Layout storage builders = LibBuilderFeesStorage.layout();
            builders.totalNativeEthLiability += purchase.builderFee;
            builders.provisionalNativeEthLiability += purchase.builderFee;
            LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
            settlements.provisionalBuilderCreditEth[purchase.roundId][builder] += purchase.builderFee;
            settlements.builderRefundEth[purchase.roundId][msg.sender] += purchase.builderFee;
            settlements.rounds[purchase.roundId].builderFeeEth += purchase.builderFee;
            emit ICrottoBuilderFees.BuilderFeeAccrued(
                msg.sender, builder, purchase.roundId, quantity, builderFeeBps, purchase.builderFee
            );
        }
        if (purchase.rewardRedirectEffective) {
            emit ICrottoBuilderFees.TicketRewardBeneficiarySelected(msg.sender, builder, purchase.roundId, quantity);
        }
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

    function _quotableRound(uint256 roundId, uint256 quantity) private view returns (Round storage storedRound) {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        if (roundId == 0 || roundId > lottery.currentRoundId) revert UnknownRound(roundId);
        if (quantity == 0) revert InvalidTicketQuantity();
        storedRound = lottery.rounds[roundId];
        uint256 remaining = storedRound.config.ticketTarget - storedRound.ticketCount;
        if (quantity > remaining) revert TicketQuantityExceedsRemaining(quantity, remaining);
    }

    function _quote(RoundConfiguration storage configuration, uint256 quantity)
        private
        view
        returns (uint256 ticketValue, uint256 operationsContribution, uint256 requiredPayment)
    {
        ticketValue = configuration.ticketPrice * quantity;
        operationsContribution = configuration.ticketOperationsFee * quantity;
        requiredPayment = ticketValue + operationsContribution;
    }
}
