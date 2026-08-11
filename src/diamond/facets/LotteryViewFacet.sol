// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {LibRewardAccounting} from "../../libraries/LibRewardAccounting.sol";
import {LibBuilderFeesStorage} from "../../libraries/storage/LibBuilderFeesStorage.sol";
import {LibPOLStorage} from "../../libraries/storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {LibRoundSettlementStorage} from "../../libraries/storage/LibRoundSettlementStorage.sol";
import {LibTreasuryStorage} from "../../libraries/storage/LibTreasuryStorage.sol";
import {LibVaultStorage} from "../../libraries/storage/LibVaultStorage.sol";
import {ProtocolAccountingView, RequestRecord, Round, RoundSettlement, TicketBatch} from "../../types/CrottoTypes.sol";

/// @notice Bounded round, ticket-batch, player, and randomness-attempt views.
contract LotteryViewFacet {
    error UnknownRound(uint256 roundId);
    error InvalidTicketBatchIndex(uint256 roundId, uint256 index, uint256 count);

    function currentRoundId() external view returns (uint256) {
        return LibLotteryStorage.layout().currentRoundId;
    }

    function round(uint256 roundId) external view returns (Round memory) {
        _enforceRoundExists(roundId);
        return LibLotteryStorage.layout().rounds[roundId];
    }

    function remainingTickets(uint256 roundId) external view returns (uint256) {
        _enforceRoundExists(roundId);
        Round storage storedRound = LibLotteryStorage.layout().rounds[roundId];
        return storedRound.config.ticketTarget - storedRound.ticketCount;
    }

    function ticketBatchCount(uint256 roundId) external view returns (uint256) {
        _enforceRoundExists(roundId);
        return LibLotteryStorage.layout().ticketBatches[roundId].length;
    }

    function ticketBatch(uint256 roundId, uint256 index) external view returns (TicketBatch memory) {
        _enforceRoundExists(roundId);
        TicketBatch[] storage batches = LibLotteryStorage.layout().ticketBatches[roundId];
        uint256 count = batches.length;
        if (index >= count) revert InvalidTicketBatchIndex(roundId, index, count);
        return batches[index];
    }

    function playerTickets(uint256 roundId, address player) external view returns (uint256) {
        _enforceRoundExists(roundId);
        return LibLotteryStorage.layout().playerTicketCounts[roundId][player];
    }

    function rewardTickets(uint256 roundId, address beneficiary) external view returns (uint256) {
        _enforceRoundExists(roundId);
        return LibLotteryStorage.layout().rewardTicketCounts[roundId][beneficiary];
    }

    function playerRewardClaimed(uint256 roundId, address player) external view returns (bool) {
        _enforceRoundExists(roundId);
        return LibLotteryStorage.layout().playerRewardClaimed[roundId][player];
    }

    function playerRewardEntitlement(uint256 roundId, address beneficiary) external view returns (uint256) {
        _enforceRoundExists(roundId);
        LibLotteryStorage.Layout storage state = LibLotteryStorage.layout();
        return state.rewardTicketCounts[roundId][beneficiary] * state.rounds[roundId].config.playerRewardRate;
    }

    function requestRecord(uint256 requestId) external view returns (RequestRecord memory) {
        return LibLotteryStorage.layout().requests[requestId];
    }

    function roundSettlement(uint256 roundId) external view returns (RoundSettlement memory) {
        _enforceRoundExists(roundId);
        return LibRoundSettlementStorage.layout().rounds[roundId];
    }

    function expiredRoundRefund(uint256 roundId, address buyer)
        external
        view
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth, bool claimed)
    {
        _enforceRoundExists(roundId);
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        ticketRefundWeth = lottery.playerTicketCounts[roundId][buyer] * lottery.rounds[roundId].config.ticketPrice;
        builderRefundEth = settlements.builderRefundEth[roundId][buyer];
        claimed = settlements.refundClaimed[roundId][buyer];
    }

    function protocolAccounting() external view returns (ProtocolAccountingView memory accounting) {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        LibRewardsStorage.Layout storage rewards = LibRewardsStorage.layout();
        LibTreasuryStorage.Layout storage treasury = LibTreasuryStorage.layout();
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        accounting.winnerPoolWethLiability = lottery.totalWinnerPoolWethLiability;
        accounting.rewardNftWethLiability =
            LibRewardAccounting.outstanding(rewards.wethBook) + settlements.lotteryNftWethLiability;
        accounting.bootstrapPolWeth = LibPOLStorage.layout().bootstrapWeth;
        accounting.operationsReserveEth = treasury.operationsReserveEth;
        accounting.callerCreditsEth = treasury.totalCallerCreditsEth;
        accounting.playerTokenLiability = lottery.totalPlayerTokenLiability;
        accounting.rewardNftTokenLiability = LibRewardAccounting.outstanding(rewards.tokenBook);
        accounting.vaultBackingToken = LibVaultStorage.layout().tokenBacking;
        accounting.ticketEscrowWeth = settlements.activeTicketEscrowWeth;
        accounting.expiredTicketRefundWeth = settlements.expiredTicketRefundWeth;
        accounting.pendingBuybackWeth = settlements.pendingBuybackWeth;
        accounting.provisionalBuilderEth = LibBuilderFeesStorage.layout().provisionalNativeEthLiability;
        accounting.expiredBuilderRefundEth = settlements.expiredBuilderRefundEth;
    }

    function _enforceRoundExists(uint256 roundId) private view {
        uint256 latestRoundId = LibLotteryStorage.layout().currentRoundId;
        if (roundId == 0 || roundId > latestRoundId) revert UnknownRound(roundId);
    }
}
