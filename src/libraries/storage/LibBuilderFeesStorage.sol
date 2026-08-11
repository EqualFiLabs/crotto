// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BuilderApproval} from "../../types/CrottoTypes.sol";

/// @notice Player-controlled Builder approvals and isolated native ETH liabilities.
library LibBuilderFeesStorage {
    bytes32 internal constant STORAGE_SLOT = 0xf72c46b5dd916213bdce28eabf2ae57f26b2de802871ac665f818c7922fad000;

    /// @custom:storage-location erc7201:crotto.storage.BuilderFees
    struct Layout {
        mapping(address player => mapping(address builder => BuilderApproval)) approvals;
        mapping(address builder => uint256 nativeCredit) credits;
        uint256 totalNativeEthLiability;
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
