// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ICrotto} from "../interfaces/ICrotto.sol";
import {LibLotteryStorage} from "./storage/LibLotteryStorage.sol";
import {Round, RoundConfiguration, RoundStatus} from "../types/CrottoTypes.sol";

/// @notice Internal initialization and rollover primitives for isolated sellout rounds.
library LibLottery {
    error LotteryAlreadyInitialized(uint256 currentRoundId);
    error InvalidRolloverRound(uint256 finalizedRoundId, uint256 currentRoundId);

    function initializeFirstRound(RoundConfiguration memory configuration) internal returns (uint256 roundId) {
        LibLotteryStorage.Layout storage state = LibLotteryStorage.layout();
        if (state.currentRoundId != 0) revert LotteryAlreadyInitialized(state.currentRoundId);

        roundId = 1;
        state.currentRoundId = roundId;
        Round storage initializedRound = state.rounds[roundId];
        initializedRound.status = RoundStatus.Open;
        initializedRound.config = configuration;

        emit ICrotto.RoundInitialized(roundId);
    }

    function initializeNextRound(uint256 finalizedRoundId, RoundConfiguration memory configuration)
        internal
        returns (uint256 roundId)
    {
        LibLotteryStorage.Layout storage state = LibLotteryStorage.layout();
        uint256 currentRoundId = state.currentRoundId;
        if (currentRoundId != finalizedRoundId) revert InvalidRolloverRound(finalizedRoundId, currentRoundId);

        roundId = currentRoundId + 1;
        state.currentRoundId = roundId;
        Round storage initializedRound = state.rounds[roundId];
        initializedRound.status = RoundStatus.Open;
        initializedRound.config = configuration;

        emit ICrotto.RoundInitialized(roundId);
    }
}
