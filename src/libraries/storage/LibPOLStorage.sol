// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Bootstrap WETH custody and one-time canonical POL authorization state.
library LibPOLStorage {
    bytes32 internal constant STORAGE_SLOT = 0xf6d0e59e3985d4bcca59f2d7eb25b8c373f6710eeb2aaea5b016fb2726741c00;

    /// @custom:storage-location erc7201:crotto.storage.POL
    struct Layout {
        uint256 bootstrapWeth;
        PoolId canonicalPoolId;
        bool initialized;
        bool initializationAuthorized;
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
