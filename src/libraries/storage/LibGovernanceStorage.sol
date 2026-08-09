// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {
    ActivationConfiguration,
    HookConfiguration,
    ImmutableConfiguration,
    RoundConfiguration
} from "../../types/CrottoTypes.sol";

/// @notice Governance configuration and bounded pause state.
library LibGovernanceStorage {
    bytes32 internal constant STORAGE_SLOT = 0xcd70f255548aff87a13a50c653b0d48a0747ca996943257c19edb22a4bc76900;

    /// @custom:storage-location erc7201:crotto.storage.Governance
    struct Layout {
        ImmutableConfiguration immutableConfiguration;
        RoundConfiguration roundConfiguration;
        ActivationConfiguration activationConfiguration;
        HookConfiguration hookConfiguration;
        address treasury;
        address guardian;
        uint64 activationConfigurationVersion;
        uint256 pausedActions;
        bool immutableConfigurationInitialized;
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
