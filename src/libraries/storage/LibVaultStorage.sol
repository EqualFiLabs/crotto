// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Isolated TOKEN backing for Reward NFTs outside Diamond custody.
library LibVaultStorage {
    bytes32 internal constant STORAGE_SLOT = 0xa9bdee6d4d288e170c790a5de59574b86c8e1cf08329c4df31c0ed16688cf900;

    /// @custom:storage-location erc7201:crotto.storage.Vault
    struct Layout {
        uint256 tokenBacking;
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
