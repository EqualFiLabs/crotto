// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {RequestRecord, Round, TicketBatch} from "../../types/CrottoTypes.sol";

/// @notice Sellout-round, ticket, request, and player-claim state.
library LibLotteryStorage {
    bytes32 internal constant STORAGE_SLOT = 0x0a6720d3cb408016da14fcc6d77bec9a97814ec8efce09c3a83e37c51e2f2e00;

    /// @custom:storage-location erc7201:crotto.storage.Lottery
    struct Layout {
        uint256 currentRoundId;
        mapping(uint256 roundId => Round) rounds;
        mapping(uint256 roundId => TicketBatch[]) ticketBatches;
        mapping(uint256 roundId => mapping(address player => uint256 count)) playerTicketCounts;
        mapping(uint256 roundId => mapping(address player => bool claimed)) playerRewardClaimed;
        mapping(uint256 requestId => RequestRecord) requests;
    }

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = STORAGE_SLOT;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }

    function storageSlot() internal pure returns (bytes32) {
        return STORAGE_SLOT;
    }
}
