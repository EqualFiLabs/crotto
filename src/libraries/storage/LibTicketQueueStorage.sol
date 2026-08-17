// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {TicketOrder} from "../../types/CrottoTypes.sol";

/// @notice Persistent FIFO ticket orders and isolated queue escrow/refund books.
library LibTicketQueueStorage {
    bytes32 internal constant STORAGE_SLOT = 0xc99a9b374248749116f36f20a77de9faaf6cc6137aa3edc113ed6d420e864700;

    /// @custom:storage-location erc7201:crotto.storage.TicketQueue
    struct Layout {
        uint256 activeGeneration;
        bytes32 activeConfigurationHash;
        uint256 nextOrderId;
        uint256 headOrderId;
        uint256 tailOrderId;
        uint256 roundCursorOrderId;
        mapping(uint256 orderId => TicketOrder order) orders;
        mapping(uint256 generation => bool invalidated) generationInvalidated;
        mapping(uint256 generation => bytes32 configurationHash) generationConfigurationHash;
        uint256 activeTicketEscrowWeth;
        uint256 activeBuilderEscrowEth;
        uint256 invalidatedTicketRefundWeth;
        uint256 invalidatedBuilderRefundEth;
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
