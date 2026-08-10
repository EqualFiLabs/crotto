// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IDiamondCut} from "../../interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../interfaces/diamond/IERC173.sol";
import {ICrottoGovernance} from "../../interfaces/ICrottoGovernance.sol";
import {IActivationToken} from "../../interfaces/IActivationToken.sol";
import {IRewardNFT} from "../../interfaces/IRewardNFT.sol";
import {ICrottoSwapFeeHook} from "../../interfaces/ICrottoSwapFeeHook.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibLottery} from "../../libraries/LibLottery.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {GovernanceInitialization} from "../../types/CrottoTypes.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice One-time core interface registration executed in Diamond storage context.
contract CrottoDiamondInit {
    error CanonicalHookHasNoCode(address hook);
    error RewardNFTHasNoCode(address rewardNft);
    error RewardNFTUnsupportedInterface(address rewardNft);
    error RewardNFTDiamondMismatch(address rewardNft, address configuredDiamond, address expectedDiamond);
    error RewardNFTMaxSupplyMismatch(address rewardNft, uint256 configuredMaxSupply, uint256 actualMaxSupply);
    error ActivationTokenHasNoCode(address token);
    error WethHasNoCode(address weth);
    error ActivationTokenDiamondMismatch(address token, address configuredDiamond, address expectedDiamond);
    error ActivationTokenHookMismatch(address token, address configuredHook, address expectedHook);

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
        LibCrottoValidation.validateActivationConfiguration(
            initialization.activationConfiguration, initialization.immutableConfiguration.rewardNFTMaxSupply
        );
        LibCrottoValidation.validateHookConfiguration(
            initialization.hookConfiguration, initialization.immutableConfiguration.maxCombinedHookFeeBps
        );
        LibCrottoValidation.validateTreasuryReceiver(
            initialization.treasuryReceiver, initialization.immutableConfiguration
        );

        address weth = initialization.immutableConfiguration.weth;
        if (weth.code.length == 0) revert WethHasNoCode(weth);

        _validateRewardNft(initialization);

        address hook = initialization.immutableConfiguration.canonicalHook;
        if (hook.code.length == 0) revert CanonicalHookHasNoCode(hook);
        _validateActivationToken(initialization);

        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.immutableConfiguration = initialization.immutableConfiguration;
        state.roundConfiguration = initialization.roundConfiguration;
        state.activationConfiguration = initialization.activationConfiguration;
        state.hookConfiguration = initialization.hookConfiguration;
        state.treasuryReceiver = initialization.treasuryReceiver;
        state.guardian = initialization.guardian;
        state.activationConfigurationVersion = 1;
        state.immutableConfigurationInitialized = true;

        LibLottery.initializeFirstRound(initialization.roundConfiguration);

        ICrottoSwapFeeHook(hook).setHookConfiguration(initialization.hookConfiguration);

        LibDiamond.setSupportedInterface(type(ICrottoGovernance).interfaceId, true);
        LibDiamond.markCoreInterfacesInitialized();

        emit ICrottoGovernance.RoundConfigurationSet(initialization.roundConfiguration);
        emit ICrottoGovernance.ActivationConfigurationSet(1, initialization.activationConfiguration);
        emit ICrottoGovernance.HookConfigurationSet(initialization.hookConfiguration);
        emit ICrottoGovernance.TreasuryReceiverChanged(address(0), initialization.treasuryReceiver);
        emit ICrottoGovernance.GuardianChanged(address(0), initialization.guardian);
    }

    function _validateActivationToken(GovernanceInitialization calldata initialization) private view {
        address token = initialization.immutableConfiguration.activationToken;
        if (token.code.length == 0) revert ActivationTokenHasNoCode(token);

        address configuredDiamond = IActivationToken(token).crottoDiamond();
        if (configuredDiamond != address(this)) {
            revert ActivationTokenDiamondMismatch(token, configuredDiamond, address(this));
        }

        address expectedHook = initialization.immutableConfiguration.canonicalHook;
        address configuredHook = IActivationToken(token).canonicalHook();
        if (configuredHook != expectedHook) {
            revert ActivationTokenHookMismatch(token, configuredHook, expectedHook);
        }
    }

    function _validateRewardNft(GovernanceInitialization calldata initialization) private view {
        address rewardNft = initialization.immutableConfiguration.rewardNFT;
        if (rewardNft.code.length == 0) revert RewardNFTHasNoCode(rewardNft);

        bytes4[] memory requiredInterfaces = new bytes4[](3);
        requiredInterfaces[0] = type(IRewardNFT).interfaceId;
        requiredInterfaces[1] = type(IERC721).interfaceId;
        requiredInterfaces[2] = type(IERC721Metadata).interfaceId;
        if (!ERC165Checker.supportsAllInterfaces(rewardNft, requiredInterfaces)) {
            revert RewardNFTUnsupportedInterface(rewardNft);
        }

        address configuredDiamond = IRewardNFT(rewardNft).crottoDiamond();
        if (configuredDiamond != address(this)) {
            revert RewardNFTDiamondMismatch(rewardNft, configuredDiamond, address(this));
        }

        uint256 configuredMaxSupply = initialization.immutableConfiguration.rewardNFTMaxSupply;
        uint256 actualMaxSupply = IRewardNFT(rewardNft).maxSupply();
        if (actualMaxSupply != configuredMaxSupply) {
            revert RewardNFTMaxSupplyMismatch(rewardNft, configuredMaxSupply, actualMaxSupply);
        }
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
