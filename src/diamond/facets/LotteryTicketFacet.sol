// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ICrotto} from "../../interfaces/ICrotto.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibBuybackStorage} from "../../libraries/storage/LibBuybackStorage.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "../../libraries/storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {LibTreasuryStorage} from "../../libraries/storage/LibTreasuryStorage.sol";
import {Round, RoundConfiguration, RoundStatus, TicketBatch} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Exact native-ETH ticket purchases with isolated WETH and Operations accounting.
contract LotteryTicketFacet is CrottoFacet {
    error UnknownRound(uint256 roundId);
    error RoundNotOpen(uint256 roundId, RoundStatus status);
    error InvalidTicketQuantity();
    error TicketQuantityExceedsRemaining(uint256 requested, uint256 remaining);
    error IncorrectTicketPayment(uint256 expected, uint256 actual);
    error UnexpectedWethDeposit(uint256 expected, uint256 actual);

    function buyTickets(uint256 quantity)
        external
        payable
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_TICKET_PURCHASES)
    {
        if (quantity == 0) revert InvalidTicketQuantity();

        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        uint256 roundId = lottery.currentRoundId;
        Round storage currentRound = lottery.rounds[roundId];
        if (currentRound.status != RoundStatus.Open) revert RoundNotOpen(roundId, currentRound.status);

        uint256 startTicket = currentRound.ticketCount;
        uint256 remaining = currentRound.config.ticketTarget - startTicket;
        if (quantity > remaining) revert TicketQuantityExceedsRemaining(quantity, remaining);

        (uint256 ticketValue, uint256 operationsContribution, uint256 requiredPayment) =
            _quote(currentRound.config, quantity);
        if (msg.value != requiredPayment) revert IncorrectTicketPayment(requiredPayment, msg.value);

        uint256 endTicketExclusive = startTicket + quantity;
        currentRound.ticketCount = endTicketExclusive;
        lottery.ticketBatches[roundId].push(TicketBatch({endExclusive: endTicketExclusive, buyer: msg.sender}));
        lottery.playerTicketCounts[roundId][msg.sender] += quantity;

        uint256 winnerAmount = Math.mulDiv(ticketValue, currentRound.config.winnerShareBps, CrottoConstants.BPS);
        uint256 nftAmount = Math.mulDiv(ticketValue, currentRound.config.nftShareBps, CrottoConstants.BPS);
        uint256 buybackAmount = Math.mulDiv(ticketValue, currentRound.config.buybackShareBps, CrottoConstants.BPS);
        uint256 treasuryAmount = ticketValue - winnerAmount - nftAmount - buybackAmount;

        currentRound.winnerPoolWeth += winnerAmount;
        LibTreasuryStorage.layout().operationsReserveEth += operationsContribution;
        LibBuybackStorage.Layout storage buyback = LibBuybackStorage.layout();
        buyback.wethReserve += buybackAmount;
        buyback.totalTicketsSold += quantity;

        if (LibRewardsStorage.layout().totalActiveWeight != 0) {
            _accrueNftWethRewards(nftAmount);
        } else if (!LibPOLStorage.layout().initialized) {
            LibPOLStorage.layout().bootstrapWeth += nftAmount;
        } else {
            treasuryAmount += nftAmount;
        }

        if (endTicketExclusive == currentRound.config.ticketTarget) currentRound.status = RoundStatus.Closed;

        address weth = LibGovernanceStorage.layout().immutableConfiguration.weth;
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        IWETH9(weth).deposit{value: ticketValue}();
        uint256 wethAfter = IERC20(weth).balanceOf(address(this));
        uint256 wethReceived = wethAfter >= wethBefore ? wethAfter - wethBefore : 0;
        if (wethReceived != ticketValue) revert UnexpectedWethDeposit(ticketValue, wethReceived);

        LibAssetTransfer.pushExact(weth, LibGovernanceStorage.layout().treasuryReceiver, treasuryAmount);

        emit ICrotto.TicketsPurchased(
            roundId,
            msg.sender,
            quantity,
            startTicket,
            endTicketExclusive,
            ticketValue,
            operationsContribution,
            buybackAmount,
            buyback.totalTicketsSold
        );
        if (currentRound.status == RoundStatus.Closed) emit ICrotto.RoundClosed(roundId, endTicketExclusive);
    }

    function ticketQuote(uint256 roundId, uint256 quantity)
        external
        view
        returns (uint256 ticketPriceEth, uint256 operationsFeeEth, uint256 totalEth)
    {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        if (roundId == 0 || roundId > lottery.currentRoundId) revert UnknownRound(roundId);
        if (quantity == 0) revert InvalidTicketQuantity();

        Round storage storedRound = lottery.rounds[roundId];
        uint256 remaining = storedRound.config.ticketTarget - storedRound.ticketCount;
        if (quantity > remaining) revert TicketQuantityExceedsRemaining(quantity, remaining);
        return _quote(storedRound.config, quantity);
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
