// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondCut} from "../../interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../interfaces/diamond/IERC173.sol";
import {ICrottoGovernance} from "../../interfaces/ICrottoGovernance.sol";
import {ICrottoSwapFeeHook} from "../../interfaces/ICrottoSwapFeeHook.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {GovernanceInitialization} from "../../types/CrottoTypes.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice One-time core interface registration executed in Diamond storage context.
contract CrottoDiamondInit {
    error CanonicalHookHasNoCode(address hook);

    function initialize() external {
        _validateCoreSelectors();
        LibDiamond.markCoreInterfacesInitialized();
    }

    function initializeGovernance(GovernanceInitialization calldata initialization) external {
        _validateCoreSelectors();
        _validateGovernanceSelectors();

        LibCrottoValidation.validateImmutableConfiguration(initialization.immutableConfiguration);
        LibCrottoValidation.validateRoundConfiguration(initialization.roundConfiguration);
        LibCrottoValidation.validateBootstrapReachability(
            initialization.roundConfiguration, initialization.immutableConfiguration.requiredBootstrapWeth
        );
        LibCrottoValidation.validateActivationConfiguration(initialization.activationConfiguration);
        LibCrottoValidation.validateHookConfiguration(
            initialization.hookConfiguration, initialization.immutableConfiguration.maxCombinedHookFeeBps
        );
        LibCrottoValidation.validateTreasuryReceiver(initialization.treasuryReceiver);

        address hook = initialization.immutableConfiguration.canonicalHook;
        if (hook.code.length == 0) revert CanonicalHookHasNoCode(hook);

        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.immutableConfiguration = initialization.immutableConfiguration;
        state.roundConfiguration = initialization.roundConfiguration;
        state.activationConfiguration = initialization.activationConfiguration;
        state.hookConfiguration = initialization.hookConfiguration;
        state.treasuryReceiver = initialization.treasuryReceiver;
        state.guardian = initialization.guardian;
        state.activationConfigurationVersion = 1;
        state.immutableConfigurationInitialized = true;

        ICrottoSwapFeeHook(hook).setHookConfiguration(initialization.hookConfiguration);

        LibDiamond.setSupportedInterface(type(ICrottoGovernance).interfaceId, true);
        LibDiamond.markCoreInterfacesInitialized();

        emit ICrottoGovernance.RoundConfigurationSet(initialization.roundConfiguration);
        emit ICrottoGovernance.ActivationConfigurationSet(1, initialization.activationConfiguration);
        emit ICrottoGovernance.HookConfigurationSet(initialization.hookConfiguration);
        emit ICrottoGovernance.TreasuryReceiverChanged(address(0), initialization.treasuryReceiver);
        emit ICrottoGovernance.GuardianChanged(address(0), initialization.guardian);
    }

    function _validateCoreSelectors() private view {
        LibDiamond.enforceSelectorExists(IDiamondCut.diamondCut.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facets.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facetFunctionSelectors.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facetAddresses.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facetAddress.selector);
        LibDiamond.enforceSelectorExists(IERC165.supportsInterface.selector);
        LibDiamond.enforceSelectorExists(IERC173.owner.selector);
        LibDiamond.enforceSelectorExists(IERC173.transferOwnership.selector);
    }

    function _validateGovernanceSelectors() private view {
        LibDiamond.enforceSelectorExists(ICrottoGovernance.setRoundConfiguration.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.setActivationConfiguration.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.setHookConfiguration.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.setTreasuryReceiver.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.setGuardian.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.pauseActions.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.unpauseActions.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.treasuryReceiver.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.guardian.selector);
        LibDiamond.enforceSelectorExists(ICrottoGovernance.pausedActions.selector);
    }
}
