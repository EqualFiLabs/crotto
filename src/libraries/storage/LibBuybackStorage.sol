// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Isolated ticket-funded buyback inventory and lifetime eligibility state.
library LibBuybackStorage {
    bytes32 internal constant STORAGE_SLOT = 0x78254a5250280ecfbf73871a5e8e4722561538ba586405834e737d5035b2b300;

    /// @custom:storage-location erc7201:crotto.storage.Buyback
    struct Layout {
        uint256 wethReserve;
        uint256 totalTicketsSold;
        uint256 ticketsAtLastBuyback;
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
