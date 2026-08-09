// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Asset-specific treasury, Operations Reserve, and caller credits.
library LibTreasuryStorage {
    bytes32 internal constant STORAGE_SLOT = 0x2a7233fb8ccf8a4e4ec73359c08c46191205e3e1326cc296b5a8d61cfab05d00;

    /// @custom:storage-location erc7201:crotto.storage.Treasury
    struct Layout {
        uint256 treasuryWeth;
        uint256 treasuryToken;
        uint256 operationsReserveEth;
        uint256 totalCallerCreditsEth;
        mapping(address caller => uint256 amount) callerCreditsEth;
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
