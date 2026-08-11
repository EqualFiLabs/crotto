// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Reserved legacy words and transaction-scoped automatic buyback state.
library LibBuybackStorage {
    bytes32 internal constant STORAGE_SLOT = 0x657b49c746ee5ace6fa5256d702a7afbc0ae80c55b9e9f42d7aaae0269cbb700;

    /// @custom:storage-location erc7201:crotto.storage.Buyback
    struct Layout {
        uint256 __reservedLegacyWethReserve;
        uint256 __reservedLegacyTotalTicketsSold;
        uint256 __reservedLegacyTicketsAtLastBuyback;
        bytes32 activeExecutionHash;
        uint256 totalWethPurchased;
        uint256 totalTokenReceived;
        uint256 executionCount;
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
