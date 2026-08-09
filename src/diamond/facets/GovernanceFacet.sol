// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {CrottoFacet} from "../CrottoFacet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ICrottoGovernance} from "../../interfaces/ICrottoGovernance.sol";
import {ICrottoSwapFeeHook} from "../../interfaces/ICrottoSwapFeeHook.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {ActivationConfiguration, HookConfiguration, RoundConfiguration} from "../../types/CrottoTypes.sol";

/// @notice Timelock-governed economic configuration and bounded Guardian controls.
contract GovernanceFacet is CrottoFacet, ICrottoGovernance {
    error GovernanceNotInitialized();
    error NotGuardianOrOwner(address caller);
    error CanonicalHookHasNoCode(address hook);

    function setRoundConfiguration(RoundConfiguration calldata configuration) external {
        LibDiamond.enforceIsContractOwner();
        LibGovernanceStorage.Layout storage state = _governanceState();

        LibCrottoValidation.validateRoundConfiguration(configuration);
        LibCrottoValidation.validateBootstrapReachability(
            configuration, state.immutableConfiguration.requiredBootstrapWeth
        );
        state.roundConfiguration = configuration;

        emit RoundConfigurationSet(configuration);
    }

    function setActivationConfiguration(ActivationConfiguration calldata configuration) external {
        LibDiamond.enforceIsContractOwner();
        LibGovernanceStorage.Layout storage state = _governanceState();

        LibCrottoValidation.validateActivationConfiguration(configuration);
        state.activationConfiguration = configuration;
        uint64 version = ++state.activationConfigurationVersion;

        emit ActivationConfigurationSet(version, configuration);
    }

    function setHookConfiguration(HookConfiguration calldata configuration) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibGovernanceStorage.Layout storage state = _governanceState();

        LibCrottoValidation.validateHookConfiguration(configuration, state.immutableConfiguration.maxCombinedHookFeeBps);
        address hook = state.immutableConfiguration.canonicalHook;
        if (hook.code.length == 0) revert CanonicalHookHasNoCode(hook);

        state.hookConfiguration = configuration;
        ICrottoSwapFeeHook(hook).setHookConfiguration(configuration);

        emit HookConfigurationSet(configuration);
    }

    function setTreasuryReceiver(address newReceiver) external {
        LibDiamond.enforceIsContractOwner();
        LibGovernanceStorage.Layout storage state = _governanceState();

        LibCrottoValidation.validateTreasuryReceiver(newReceiver);
        address previousReceiver = state.treasuryReceiver;
        state.treasuryReceiver = newReceiver;

        emit TreasuryReceiverChanged(previousReceiver, newReceiver);
    }

    function setGuardian(address newGuardian) external {
        LibDiamond.enforceIsContractOwner();
        LibGovernanceStorage.Layout storage state = _governanceState();

        address previousGuardian = state.guardian;
        state.guardian = newGuardian;

        emit GuardianChanged(previousGuardian, newGuardian);
    }

    function pauseActions(uint256 flags) external {
        LibGovernanceStorage.Layout storage state = _governanceState();
        if (msg.sender != LibDiamond.contractOwner() && msg.sender != state.guardian) {
            revert NotGuardianOrOwner(msg.sender);
        }
        LibCrottoValidation.validatePauseFlags(flags);
        state.pausedActions |= flags;

        emit ActionsPaused(flags, msg.sender);
    }

    function unpauseActions(uint256 flags) external {
        LibDiamond.enforceIsContractOwner();
        LibGovernanceStorage.Layout storage state = _governanceState();

        LibCrottoValidation.validatePauseFlags(flags);
        state.pausedActions &= ~flags;

        emit ActionsUnpaused(flags);
    }

    function treasuryReceiver() external view returns (address) {
        return _governanceState().treasuryReceiver;
    }

    function guardian() external view returns (address) {
        return _governanceState().guardian;
    }

    function pausedActions() external view returns (uint256) {
        return _governanceState().pausedActions;
    }

    function _governanceState() private view returns (LibGovernanceStorage.Layout storage state) {
        state = LibGovernanceStorage.layout();
        if (!state.immutableConfigurationInitialized) revert GovernanceNotInitialized();
    }
}
