// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CrottoConstants} from "./CrottoConstants.sol";
import {LibDiamond} from "../diamond/libraries/LibDiamond.sol";
import {
    ActivationConfiguration,
    HookConfiguration,
    ImmutableConfiguration,
    RoundConfiguration
} from "../types/CrottoTypes.sol";

/// @notice Pure deployment and governance configuration validation.
library LibCrottoValidation {
    error ZeroAddress(bytes32 field);
    error ZeroValue(bytes32 field);
    error InvalidAllocation(uint256 totalBps);
    error InvalidTierCosts();
    error InvalidTierWeights();
    error ActivationWeightCapacityExceeded(uint256 maximumWeight, uint256 maximumSupply);
    error VaultBackingCapacityExceeded(uint256 vaultPrice, uint256 maximumSupply);
    error InvalidHookFeeCeiling(uint256 combinedFeeBps, uint256 maximumFeeBps);
    error InsufficientRoundOperationsFunding(uint256 available, uint256 required);
    error BootstrapThresholdUnreachable(uint256 available, uint256 required);
    error PlayerRewardLiabilityCapacityExceeded(uint256 rewardRate, uint256 ticketTarget);
    error InvalidPauseFlags(uint256 flags);
    error TreasuryReceiverIsProtocol(address receiver);

    function validateImmutableConfiguration(ImmutableConfiguration memory config) internal pure {
        _nonzero(config.activationToken, "activationToken");
        _nonzero(config.rewardNFT, "rewardNFT");
        _nonzero(config.weth, "weth");
        _nonzero(config.vrfWrapper, "vrfWrapper");
        _nonzero(config.uniswapV4PoolManager, "uniswapV4PoolManager");
        _nonzero(config.canonicalHook, "canonicalHook");
        _positive(config.rewardNFTMaxSupply, "rewardNFTMaxSupply");
        _positive(config.vaultPrice, "vaultPrice");
        _positive(config.requiredBootstrapWeth, "requiredBootstrapWeth");
        _positive(config.initialTokenPerWethWad, "initialTokenPerWethWad");
        _positive(config.maxCombinedHookFeeBps, "maxCombinedHookFeeBps");

        if (config.vaultPrice > type(uint256).max / config.rewardNFTMaxSupply) {
            revert VaultBackingCapacityExceeded(config.vaultPrice, config.rewardNFTMaxSupply);
        }

        if (config.maxCombinedHookFeeBps > CrottoConstants.BPS) {
            revert InvalidHookFeeCeiling(config.maxCombinedHookFeeBps, CrottoConstants.BPS);
        }
        if (config.canonicalTickSpacing <= 0) revert ZeroValue("canonicalTickSpacing");
    }

    function validateRoundConfiguration(RoundConfiguration memory config) internal pure {
        _positive(config.ticketPrice, "ticketPrice");
        _positive(config.ticketOperationsFee, "ticketOperationsFee");
        _positive(config.playerRewardRate, "playerRewardRate");
        _positive(config.ticketTarget, "ticketTarget");
        _positive(config.maxVrfCost, "maxVrfCost");
        _positive(config.vrfRetryDelay, "vrfRetryDelay");
        _positive(config.requestCallerReward, "requestCallerReward");
        _positive(config.finalizationCallerReward, "finalizationCallerReward");
        validateAllocation(config.winnerShareBps, config.nftShareBps, config.buybackShareBps, config.treasuryShareBps);

        if (config.playerRewardRate > type(uint256).max / config.ticketTarget) {
            revert PlayerRewardLiabilityCapacityExceeded(config.playerRewardRate, config.ticketTarget);
        }

        uint256 available = config.ticketOperationsFee * config.ticketTarget;
        uint256 required = config.maxVrfCost + config.requestCallerReward + config.finalizationCallerReward;
        if (available < required) revert InsufficientRoundOperationsFunding(available, required);
    }

    function validateBootstrapReachability(RoundConfiguration memory config, uint256 requiredBootstrapWeth)
        internal
        pure
    {
        _positive(requiredBootstrapWeth, "requiredBootstrapWeth");
        uint256 nftAllocationPerTicket = Math.mulDiv(config.ticketPrice, config.nftShareBps, CrottoConstants.BPS);
        uint256 nftAllocationAtSellout = nftAllocationPerTicket * config.ticketTarget;
        if (nftAllocationAtSellout < requiredBootstrapWeth) {
            revert BootstrapThresholdUnreachable(nftAllocationAtSellout, requiredBootstrapWeth);
        }
    }

    function validateActivationConfiguration(ActivationConfiguration memory config, uint256 maximumSupply)
        internal
        pure
    {
        if (!(config.costs[0] < config.costs[1] && config.costs[1] < config.costs[2])) {
            revert InvalidTierCosts();
        }
        if (!(config.destinationWeights[0] > 0 && config.destinationWeights[0] < config.destinationWeights[1]
                    && config.destinationWeights[1] < config.destinationWeights[2])) {
            revert InvalidTierWeights();
        }
        if (maximumSupply == 0 || config.destinationWeights[2] > type(uint256).max / maximumSupply) {
            revert ActivationWeightCapacityExceeded(config.destinationWeights[2], maximumSupply);
        }
        validateAllocation(config.burnShareBps, config.nftShareBps, config.treasuryShareBps);
    }

    function validateHookConfiguration(HookConfiguration memory config, uint16 maximumCombinedFeeBps) internal pure {
        uint256 combinedFeeBps = uint256(config.inputFeeBps) + config.outputFeeBps;
        if (combinedFeeBps > maximumCombinedFeeBps) {
            revert InvalidHookFeeCeiling(combinedFeeBps, maximumCombinedFeeBps);
        }
        validateAllocation(config.polShareBps, config.nftShareBps, config.treasuryShareBps);
    }

    /// @dev This remains `view` so `address(this)` resolves to the Diamond during delegatecall and prevents
    ///      configuring protocol custody as its own exact-delta Treasury Receiver.
    function validateTreasuryReceiver(address receiver, ImmutableConfiguration memory immutableConfig) internal view {
        _nonzero(receiver, "treasuryReceiver");
        if (isProtocolAddress(receiver, immutableConfig)) revert TreasuryReceiverIsProtocol(receiver);
    }

    function isProtocolAddress(address candidate, ImmutableConfiguration memory immutableConfig)
        internal
        view
        returns (bool)
    {
        return candidate == address(this) || candidate == immutableConfig.activationToken
            || candidate == immutableConfig.rewardNFT || candidate == immutableConfig.weth
            || candidate == immutableConfig.vrfWrapper || candidate == immutableConfig.uniswapV4PoolManager
            || candidate == immutableConfig.canonicalHook
            || LibDiamond.diamondStorage().facetFunctionSelectors[candidate].functionSelectors.length != 0;
    }

    function validateAllocation(uint16 firstShareBps, uint16 secondShareBps, uint16 thirdShareBps) internal pure {
        uint256 totalBps = uint256(firstShareBps) + secondShareBps + thirdShareBps;
        if (totalBps != CrottoConstants.BPS) revert InvalidAllocation(totalBps);
    }

    function validateAllocation(
        uint16 firstShareBps,
        uint16 secondShareBps,
        uint16 thirdShareBps,
        uint16 fourthShareBps
    ) internal pure {
        uint256 totalBps = uint256(firstShareBps) + secondShareBps + thirdShareBps + fourthShareBps;
        if (totalBps != CrottoConstants.BPS) revert InvalidAllocation(totalBps);
    }

    function validatePauseFlags(uint256 flags) internal pure {
        if (flags == 0 || (flags & ~CrottoConstants.ALL_PAUSE_FLAGS) != 0) revert InvalidPauseFlags(flags);
    }

    function _nonzero(address value, bytes32 field) private pure {
        if (value == address(0)) revert ZeroAddress(field);
    }

    function _positive(uint256 value, bytes32 field) private pure {
        if (value == 0) revert ZeroValue(field);
    }
}
