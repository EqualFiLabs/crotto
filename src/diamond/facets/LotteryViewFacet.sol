// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {RequestRecord, Round, TicketBatch} from "../../types/CrottoTypes.sol";

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

    function _enforceRoundExists(uint256 roundId) private view {
        uint256 latestRoundId = LibLotteryStorage.layout().currentRoundId;
        if (roundId == 0 || roundId > latestRoundId) revert UnknownRound(roundId);
    }
}
