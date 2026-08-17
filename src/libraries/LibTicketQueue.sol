// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICrotto} from "../interfaces/ICrotto.sol";
import {ICrottoBuilderFees} from "../interfaces/ICrottoBuilderFees.sol";
import {CrottoConstants} from "./CrottoConstants.sol";
import {LibProvisionalRewardAccounting} from "./LibProvisionalRewardAccounting.sol";
import {LibBuilderFeesStorage} from "./storage/LibBuilderFeesStorage.sol";
import {LibLotteryStorage} from "./storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "./storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "./storage/LibRewardsStorage.sol";
import {LibRoundSettlementStorage} from "./storage/LibRoundSettlementStorage.sol";
import {LibTicketQueueStorage} from "./storage/LibTicketQueueStorage.sol";
import {
    Round,
    RoundConfiguration,
    RoundSettlement,
    RoundStatus,
    TicketBatch,
    TicketOrder
} from "../types/CrottoTypes.sol";

/// @notice Persistent FIFO admission, bounded per-round allocation, and generation invalidation.
library LibTicketQueue {
    error InvalidTicketOrderQuantity(uint256 totalTickets, uint256 ticketsPerRound);
    error UnknownTicketOrder(uint256 orderId);
    error TicketOrderNotOwned(uint256 orderId, address caller, address owner);
    error TicketOrderRefundUnavailable(uint256 orderId);

    struct Submission {
        address owner;
        address builder;
        address rewardBeneficiary;
        uint16 builderFeeBps;
        bool rewardRedirectEffective;
        uint256 totalTickets;
        uint256 ticketsPerRound;
        uint256 ticketEscrowWeth;
        uint256 operationsFeeEth;
        uint256 totalBuilderFee;
    }

    function configurationHash(RoundConfiguration memory configuration) internal pure returns (bytes32) {
        return keccak256(abi.encode(configuration));
    }

    function validateQuantities(uint256 totalTickets, uint256 ticketsPerRound) internal pure {
        if (totalTickets == 0 || ticketsPerRound == 0 || ticketsPerRound > totalTickets) {
            revert InvalidTicketOrderQuantity(totalTickets, ticketsPerRound);
        }
    }

    function submit(Submission memory submission) internal returns (uint256 orderId) {
        validateQuantities(submission.totalTickets, submission.ticketsPerRound);

        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage currentRound = lottery.rounds[lottery.currentRoundId];
        bytes32 configHash = configurationHash(currentRound.config);
        LibTicketQueueStorage.Layout storage queue = LibTicketQueueStorage.layout();
        _syncGeneration(queue, configHash);

        orderId = ++queue.nextOrderId;
        TicketOrder storage order = queue.orders[orderId];
        order.owner = submission.owner;
        order.builder = submission.builder;
        order.rewardBeneficiary = submission.rewardBeneficiary;
        order.builderFeeBps = submission.builderFeeBps;
        order.rewardRedirectEffective = submission.rewardRedirectEffective;
        order.totalTickets = submission.totalTickets;
        order.remainingTickets = submission.totalTickets;
        order.ticketsPerRound = submission.ticketsPerRound;
        order.generation = queue.activeGeneration;
        order.configurationHash = configHash;
        order.ticketPrice = currentRound.config.ticketPrice;
        order.totalBuilderFee = submission.totalBuilderFee;

        uint256 previousTail = queue.tailOrderId;
        order.previousOrderId = previousTail;
        if (previousTail == 0) queue.headOrderId = orderId;
        else queue.orders[previousTail].nextOrderId = orderId;
        queue.tailOrderId = orderId;
        if (currentRound.status == RoundStatus.Open && queue.roundCursorOrderId == 0) {
            queue.roundCursorOrderId = orderId;
        }

        queue.activeTicketEscrowWeth += submission.ticketEscrowWeth;
        queue.activeBuilderEscrowEth += submission.totalBuilderFee;
        if (submission.totalBuilderFee != 0) {
            LibBuilderFeesStorage.layout().totalNativeEthLiability += submission.totalBuilderFee;
        }

        emit ICrotto.TicketOrderSubmitted(
            orderId,
            submission.owner,
            queue.activeGeneration,
            configHash,
            submission.totalTickets,
            submission.ticketsPerRound,
            submission.ticketEscrowWeth,
            submission.operationsFeeEth,
            submission.totalBuilderFee
        );
    }

    function processCurrentRound() internal {
        _process();
    }

    function processNewRound() internal {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage currentRound = lottery.rounds[lottery.currentRoundId];
        LibTicketQueueStorage.Layout storage queue = LibTicketQueueStorage.layout();
        _syncGeneration(queue, configurationHash(currentRound.config));
        queue.roundCursorOrderId = queue.headOrderId;
        _process();
    }

    function consumeInvalidatedRefund(uint256 orderId, address owner)
        internal
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth)
    {
        LibTicketQueueStorage.Layout storage queue = LibTicketQueueStorage.layout();
        TicketOrder storage order = queue.orders[orderId];
        if (order.owner == address(0)) revert UnknownTicketOrder(orderId);
        if (order.owner != owner) revert TicketOrderNotOwned(orderId, owner, order.owner);
        if (order.refundClaimed || !queue.generationInvalidated[order.generation]) {
            revert TicketOrderRefundUnavailable(orderId);
        }

        ticketRefundWeth = order.remainingTickets * order.ticketPrice;
        builderRefundEth = order.totalBuilderFee - order.allocatedBuilderFee;
        if (ticketRefundWeth == 0 && builderRefundEth == 0) revert TicketOrderRefundUnavailable(orderId);

        order.refundClaimed = true;
        queue.invalidatedTicketRefundWeth -= ticketRefundWeth;
        queue.invalidatedBuilderRefundEth -= builderRefundEth;
        if (builderRefundEth != 0) LibBuilderFeesStorage.layout().totalNativeEthLiability -= builderRefundEth;
    }

    function _process() private {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        uint256 roundId = lottery.currentRoundId;
        Round storage currentRound = lottery.rounds[roundId];
        if (currentRound.status != RoundStatus.Open) return;

        LibTicketQueueStorage.Layout storage queue = LibTicketQueueStorage.layout();
        uint256 cursor = queue.roundCursorOrderId;
        uint256 remainingCapacity = currentRound.config.ticketTarget - currentRound.ticketCount;
        while (cursor != 0 && remainingCapacity != 0) {
            TicketOrder storage order = queue.orders[cursor];
            uint256 next = order.nextOrderId;
            uint256 filled = Math.min(Math.min(order.remainingTickets, order.ticketsPerRound), remainingCapacity);
            _allocate(queue, lottery, currentRound, roundId, cursor, order, filled);
            remainingCapacity -= filled;
            cursor = next;
        }
        queue.roundCursorOrderId = cursor;
    }

    function _allocate(
        LibTicketQueueStorage.Layout storage queue,
        LibLotteryStorage.Layout storage lottery,
        Round storage currentRound,
        uint256 roundId,
        uint256 orderId,
        TicketOrder storage order,
        uint256 quantity
    ) private {
        uint256 startTicket = currentRound.ticketCount;
        uint256 endTicketExclusive = startTicket + quantity;
        uint256 ticketValue = quantity * order.ticketPrice;
        uint256 newRemaining = order.remainingTickets - quantity;
        uint256 cumulativeFilled = order.totalTickets - newRemaining;
        uint256 newAllocatedBuilderFee = Math.mulDiv(order.totalBuilderFee, cumulativeFilled, order.totalTickets);
        uint256 trancheBuilderFee = newAllocatedBuilderFee - order.allocatedBuilderFee;

        order.remainingTickets = newRemaining;
        order.allocatedBuilderFee = newAllocatedBuilderFee;
        currentRound.ticketCount = endTicketExclusive;
        lottery.ticketBatches[roundId].push(TicketBatch({endExclusive: endTicketExclusive, buyer: order.owner}));
        lottery.playerTicketCounts[roundId][order.owner] += quantity;
        lottery.rewardTicketCounts[roundId][order.rewardBeneficiary] += quantity;

        queue.activeTicketEscrowWeth -= ticketValue;
        queue.activeBuilderEscrowEth -= trancheBuilderFee;
        _routeTicketValue(roundId, currentRound, ticketValue);
        _accrueBuilderTranche(roundId, order, quantity, trancheBuilderFee);

        if (newRemaining == 0) _unlink(queue, orderId, order);

        emit ICrotto.TicketOrderAllocated(
            orderId,
            roundId,
            order.owner,
            quantity,
            newRemaining,
            startTicket,
            endTicketExclusive,
            ticketValue,
            trancheBuilderFee
        );
        if (endTicketExclusive == currentRound.config.ticketTarget) {
            currentRound.status = RoundStatus.Closed;
            currentRound.closedAtBlock = uint64(block.number);
            emit ICrotto.RoundClosed(roundId, endTicketExclusive);
        }
    }

    function _routeTicketValue(uint256 roundId, Round storage currentRound, uint256 ticketValue) private {
        uint256 winnerAmount = Math.mulDiv(ticketValue, currentRound.config.winnerShareBps, CrottoConstants.BPS);
        uint256 nftAmount = Math.mulDiv(ticketValue, currentRound.config.nftShareBps, CrottoConstants.BPS);
        uint256 buybackAmount = Math.mulDiv(ticketValue, currentRound.config.buybackShareBps, CrottoConstants.BPS);
        uint256 treasuryAmount = ticketValue - winnerAmount - nftAmount - buybackAmount;

        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        RoundSettlement storage settlement = settlements.rounds[roundId];
        settlement.ticketEscrowWeth += ticketValue;
        settlement.winnerWeth += winnerAmount;
        settlements.activeTicketEscrowWeth += ticketValue;

        bool activeRewardNfts = LibRewardsStorage.layout().totalActiveWeight != 0;
        bool polInitialized = LibPOLStorage.layout().initialized;
        if (activeRewardNfts) {
            LibProvisionalRewardAccounting.accrue(roundId, nftAmount, LibRewardsStorage.layout().totalActiveWeight);
        } else if (!polInitialized) {
            settlement.bootstrapPolWeth += nftAmount;
        } else {
            treasuryAmount += nftAmount;
        }
        if (!polInitialized) settlement.bootstrapPolWeth += buybackAmount;
        else settlement.buybackWeth += buybackAmount;
        settlement.treasuryWeth += treasuryAmount;
    }

    function _accrueBuilderTranche(
        uint256 roundId,
        TicketOrder storage order,
        uint256 quantity,
        uint256 trancheBuilderFee
    ) private {
        if (trancheBuilderFee != 0) {
            LibBuilderFeesStorage.layout().provisionalNativeEthLiability += trancheBuilderFee;
            LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
            settlements.provisionalBuilderCreditEth[roundId][order.builder] += trancheBuilderFee;
            settlements.builderRefundEth[roundId][order.owner] += trancheBuilderFee;
            settlements.rounds[roundId].builderFeeEth += trancheBuilderFee;
            emit ICrottoBuilderFees.BuilderFeeAccrued(
                order.owner, order.builder, roundId, quantity, order.builderFeeBps, trancheBuilderFee
            );
        }
        if (order.rewardRedirectEffective) {
            emit ICrottoBuilderFees.TicketRewardBeneficiarySelected(
                order.owner, order.rewardBeneficiary, roundId, quantity
            );
        }
    }

    function _unlink(LibTicketQueueStorage.Layout storage queue, uint256 orderId, TicketOrder storage order) private {
        uint256 previous = order.previousOrderId;
        uint256 next = order.nextOrderId;
        if (previous == 0) queue.headOrderId = next;
        else queue.orders[previous].nextOrderId = next;
        if (next == 0) queue.tailOrderId = previous;
        else queue.orders[next].previousOrderId = previous;
        order.previousOrderId = 0;
        order.nextOrderId = 0;
        if (queue.roundCursorOrderId == orderId) queue.roundCursorOrderId = next;
    }

    function _syncGeneration(LibTicketQueueStorage.Layout storage queue, bytes32 configHash) private {
        uint256 generation = queue.activeGeneration;
        if (generation == 0) {
            queue.activeGeneration = 1;
            queue.activeConfigurationHash = configHash;
            queue.generationConfigurationHash[1] = configHash;
            return;
        }
        if (queue.activeConfigurationHash == configHash) return;

        queue.generationInvalidated[generation] = true;
        uint256 ticketRefundWeth = queue.activeTicketEscrowWeth;
        uint256 builderRefundEth = queue.activeBuilderEscrowEth;
        queue.invalidatedTicketRefundWeth += ticketRefundWeth;
        queue.invalidatedBuilderRefundEth += builderRefundEth;
        queue.activeTicketEscrowWeth = 0;
        queue.activeBuilderEscrowEth = 0;
        queue.headOrderId = 0;
        queue.tailOrderId = 0;
        queue.roundCursorOrderId = 0;
        emit ICrotto.TicketQueueGenerationInvalidated(
            generation, queue.activeConfigurationHash, ticketRefundWeth, builderRefundEth
        );

        uint256 nextGeneration = generation + 1;
        queue.activeGeneration = nextGeneration;
        queue.activeConfigurationHash = configHash;
        queue.generationConfigurationHash[nextGeneration] = configHash;
    }
}
