// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CrottoConstants} from "./CrottoConstants.sol";
import {LibCanonicalPool} from "./LibCanonicalPool.sol";
import {LibDiamond} from "../diamond/libraries/LibDiamond.sol";
import {
    ActivationConfiguration,
    BuybackConfiguration,
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
    error OperationsReserveCapBelowRoundRequirement(uint256 cap, uint256 required);
    error BootstrapThresholdUnreachable(uint256 available, uint256 required);
    error PlayerRewardLiabilityCapacityExceeded(uint256 rewardRate, uint256 ticketTarget);
    error TicketPaymentCapacityExceeded(uint256 ticketPrice, uint256 operationsFee, uint256 ticketTarget);
    error BuilderTicketPaymentCapacityExceeded(uint256 canonicalPayment, uint256 builderFee, uint256 ticketTarget);
    error InvalidCanonicalTickSpacing(int24 tickSpacing);
    error InvalidPauseFlags(uint256 flags);
    error TreasuryReceiverIsProtocol(address receiver);
    error InvalidBuybackCallerTip(uint256 callerTipBps);
    error InvalidBuybackMaximumChunk(uint256 maximumWethChunk);
    error InvalidVrfTimeout(uint256 timeoutBlocks, uint256 minimum, uint256 maximum);

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
        _positive(config.vrfCallbackGasLimit, "vrfCallbackGasLimit");
        _positive(config.vrfRequestConfirmations, "vrfRequestConfirmations");

        if (config.vaultPrice > type(uint256).max / config.rewardNFTMaxSupply) {
            revert VaultBackingCapacityExceeded(config.vaultPrice, config.rewardNFTMaxSupply);
        }

        if (config.maxCombinedHookFeeBps > CrottoConstants.BPS) {
            revert InvalidHookFeeCeiling(config.maxCombinedHookFeeBps, CrottoConstants.BPS);
        }
        if (
            config.canonicalTickSpacing < TickMath.MIN_TICK_SPACING
                || config.canonicalTickSpacing > TickMath.MAX_TICK_SPACING
        ) revert InvalidCanonicalTickSpacing(config.canonicalTickSpacing);

        LibCanonicalPool.bootstrapTokenAmount(config.requiredBootstrapWeth, config.initialTokenPerWethWad);
        LibCanonicalPool.sqrtPriceX96(config.activationToken, config.weth, config.initialTokenPerWethWad);
    }

    function validateRoundConfiguration(RoundConfiguration memory config) internal pure {
        _positive(config.ticketPrice, "ticketPrice");
        _positive(config.ticketOperationsFee, "ticketOperationsFee");
        _positive(config.playerRewardRate, "playerRewardRate");
        _positive(config.ticketTarget, "ticketTarget");
        _positive(config.maxVrfCost, "maxVrfCost");
        _positive(config.vrfTimeoutBlocks, "vrfTimeoutBlocks");
        _positive(config.requestCallerReward, "requestCallerReward");
        _positive(config.finalizationCallerReward, "finalizationCallerReward");
        validateAllocation(config.winnerShareBps, config.nftShareBps, config.treasuryShareBps, config.buybackShareBps);

        if (config.playerRewardRate > type(uint256).max / config.ticketTarget) {
            revert PlayerRewardLiabilityCapacityExceeded(config.playerRewardRate, config.ticketTarget);
        }
        if (config.ticketPrice > type(uint256).max - config.ticketOperationsFee) {
            revert TicketPaymentCapacityExceeded(config.ticketPrice, config.ticketOperationsFee, config.ticketTarget);
        }
        uint256 paymentPerTicket = config.ticketPrice + config.ticketOperationsFee;
        if (paymentPerTicket > type(uint256).max / config.ticketTarget) {
            revert TicketPaymentCapacityExceeded(config.ticketPrice, config.ticketOperationsFee, config.ticketTarget);
        }

        uint256 maximumTicketValue = config.ticketPrice * config.ticketTarget;
        uint256 maximumBuilderFee =
            Math.mulDiv(maximumTicketValue, CrottoConstants.MAX_BUILDER_FEE_BPS, CrottoConstants.BPS);
        uint256 maximumCanonicalPayment = paymentPerTicket * config.ticketTarget;
        if (maximumBuilderFee > type(uint256).max - maximumCanonicalPayment) {
            revert BuilderTicketPaymentCapacityExceeded(maximumCanonicalPayment, maximumBuilderFee, config.ticketTarget);
        }

        uint256 available = config.ticketOperationsFee * config.ticketTarget;
        uint256 required = config.maxVrfCost + config.requestCallerReward + config.finalizationCallerReward;
        if (available < required) revert InsufficientRoundOperationsFunding(available, required);
        if (config.operationsReserveCap < required) {
            revert OperationsReserveCapBelowRoundRequirement(config.operationsReserveCap, required);
        }
    }

    function validateBootstrapReachability(RoundConfiguration memory config, uint256 requiredBootstrapWeth)
        internal
        pure
    {
        _positive(requiredBootstrapWeth, "requiredBootstrapWeth");
        uint256 nftAllocationPerTicket = Math.mulDiv(config.ticketPrice, config.nftShareBps, CrottoConstants.BPS);
        uint256 buybackAllocationPerTicket =
            Math.mulDiv(config.ticketPrice, config.buybackShareBps, CrottoConstants.BPS);
        uint256 bootstrapAllocationAtSellout =
            (nftAllocationPerTicket + buybackAllocationPerTicket) * config.ticketTarget;
        if (bootstrapAllocationAtSellout < requiredBootstrapWeth) {
            revert BootstrapThresholdUnreachable(bootstrapAllocationAtSellout, requiredBootstrapWeth);
        }
    }

    function validateBuybackConfiguration(BuybackConfiguration memory config) internal pure {
        if (config.callerTipBps > CrottoConstants.MAX_BUYBACK_CALLER_TIP_BPS) {
            revert InvalidBuybackCallerTip(config.callerTipBps);
        }
        if (config.maximumWethChunk == 0 || config.maximumWethChunk > uint128(type(int128).max)) {
            revert InvalidBuybackMaximumChunk(config.maximumWethChunk);
        }
    }

    function validateVrfTimeout(uint256 timeoutBlocks, uint16 requestConfirmations) internal pure {
        uint256 minimum = uint256(requestConfirmations) + 2;
        if (timeoutBlocks < minimum || timeoutBlocks > CrottoConstants.MAX_VRF_TIMEOUT_BLOCKS) {
            revert InvalidVrfTimeout(timeoutBlocks, minimum, CrottoConstants.MAX_VRF_TIMEOUT_BLOCKS);
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
