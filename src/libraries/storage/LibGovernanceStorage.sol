// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {
    ActivationConfiguration,
    BuybackConfiguration,
    HookConfiguration,
    ImmutableConfiguration,
    RoundConfiguration
} from "../../types/CrottoTypes.sol";

/// @notice Governance configuration and bounded pause state.
library LibGovernanceStorage {
    bytes32 internal constant STORAGE_SLOT = 0xcd70f255548aff87a13a50c653b0d48a0747ca996943257c19edb22a4bc76900;

    /// @dev Retains the legacy slippage field and the removed branch-local TWAP
    /// field so active configuration can evolve without reinterpreting the
    /// established governance slot.
    struct StoredBuybackConfiguration {
        uint16 legacySlippageBps;
        uint16 callerTipBps;
        uint32 legacyTwapWindowSeconds;
        uint128 maximumWethChunk;
    }

    /// @custom:storage-location erc7201:crotto.storage.Governance
    struct Layout {
        ImmutableConfiguration immutableConfiguration;
        RoundConfiguration roundConfiguration;
        ActivationConfiguration activationConfiguration;
        HookConfiguration hookConfiguration;
        address treasuryReceiver;
        address guardian;
        uint64 activationConfigurationVersion;
        uint256 pausedActions;
        bool immutableConfigurationInitialized;
        StoredBuybackConfiguration buybackConfiguration;
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

    function storeBuybackConfiguration(Layout storage state, BuybackConfiguration memory configuration) internal {
        state.buybackConfiguration.callerTipBps = configuration.callerTipBps;
        state.buybackConfiguration.maximumWethChunk = configuration.maximumWethChunk;
    }

    function loadBuybackConfiguration(Layout storage state)
        internal
        view
        returns (BuybackConfiguration memory configuration)
    {
        configuration.callerTipBps = state.buybackConfiguration.callerTipBps;
        configuration.maximumWethChunk = state.buybackConfiguration.maximumWethChunk;
    }
}
