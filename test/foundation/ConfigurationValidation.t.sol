// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibCrottoValidation} from "../../src/libraries/LibCrottoValidation.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {
    ActivationConfiguration,
    BuybackConfiguration,
    HookConfiguration,
    ImmutableConfiguration,
    RoundConfiguration
} from "../../src/types/CrottoTypes.sol";

contract ValidationHarness {
    error HarnessValueOutOfBounds(uint256 value);

    function validateImmutableConfiguration(ImmutableConfiguration calldata configuration) external pure {
        LibCrottoValidation.validateImmutableConfiguration(configuration);
    }

    function validateRoundConfiguration(RoundConfiguration calldata configuration) external pure {
        LibCrottoValidation.validateRoundConfiguration(configuration);
    }

    function validateRoundBuybackCapacity(RoundConfiguration calldata configuration, uint256 maximumInputFeeBps)
        external
        pure
    {
        if (maximumInputFeeBps > type(uint16).max) revert HarnessValueOutOfBounds(maximumInputFeeBps);
        LibCrottoValidation.validateRoundBuybackCapacity(configuration, SafeCast.toUint16(maximumInputFeeBps));
    }

    function validateBuybackConfiguration(BuybackConfiguration calldata configuration) external pure {
        LibCrottoValidation.validateBuybackConfiguration(configuration);
    }

    function validateBootstrapReachability(RoundConfiguration calldata configuration, uint256 threshold) external pure {
        LibCrottoValidation.validateBootstrapReachability(configuration, threshold);
    }

    function validateActivationConfiguration(ActivationConfiguration calldata configuration, uint256 maximumSupply)
        external
        pure
    {
        LibCrottoValidation.validateActivationConfiguration(configuration, maximumSupply);
    }

    function validateHookConfiguration(HookConfiguration calldata configuration, uint256 maximumFeeBps) external pure {
        if (maximumFeeBps > type(uint16).max) revert HarnessValueOutOfBounds(maximumFeeBps);
        LibCrottoValidation.validateHookConfiguration(configuration, SafeCast.toUint16(maximumFeeBps));
    }

    function validateTreasuryReceiver(address receiver, ImmutableConfiguration calldata immutableConfiguration)
        external
        view
    {
        LibCrottoValidation.validateTreasuryReceiver(receiver, immutableConfiguration);
    }

    function validateAllocation(uint256 first, uint256 second, uint256 third) external pure {
        if (first > type(uint16).max) revert HarnessValueOutOfBounds(first);
        if (second > type(uint16).max) revert HarnessValueOutOfBounds(second);
        if (third > type(uint16).max) revert HarnessValueOutOfBounds(third);
        LibCrottoValidation.validateAllocation(
            SafeCast.toUint16(first), SafeCast.toUint16(second), SafeCast.toUint16(third)
        );
    }

    function validateFourWayAllocation(uint256 first, uint256 second, uint256 third, uint256 fourth) external pure {
        if (first > type(uint16).max) revert HarnessValueOutOfBounds(first);
        if (second > type(uint16).max) revert HarnessValueOutOfBounds(second);
        if (third > type(uint16).max) revert HarnessValueOutOfBounds(third);
        if (fourth > type(uint16).max) revert HarnessValueOutOfBounds(fourth);
        LibCrottoValidation.validateAllocation(
            SafeCast.toUint16(first), SafeCast.toUint16(second), SafeCast.toUint16(third), SafeCast.toUint16(fourth)
        );
    }

    function validatePauseFlags(uint256 flags) external pure {
        LibCrottoValidation.validatePauseFlags(flags);
    }
}

contract RoundConfigurationPackingHarness {
    RoundConfiguration private configuration;

    function seedLegacyAllocation(uint256 packedAllocation) external {
        assembly ("memory-safe") {
            sstore(8, packedAllocation)
        }
    }

    function allocation() external view returns (uint16 winner, uint16 nft, uint16 treasury, uint16 buyback) {
        RoundConfiguration storage stored = configuration;
        return (stored.winnerShareBps, stored.nftShareBps, stored.treasuryShareBps, stored.buybackShareBps);
    }
}

contract ConfigurationValidationTest is Test {
    bytes32 private constant CANONICAL_HOOK_FIELD = "canonicalHook";
    bytes32 private constant PLAYER_REWARD_RATE_FIELD = "playerRewardRate";
    bytes32 private constant TREASURY_RECEIVER_FIELD = "treasuryReceiver";
    bytes32 private constant UNISWAP_V4_POOL_MANAGER_FIELD = "uniswapV4PoolManager";
    bytes32 private constant VAULT_PRICE_FIELD = "vaultPrice";
    bytes32 private constant VRF_CALLBACK_GAS_LIMIT_FIELD = "vrfCallbackGasLimit";
    bytes32 private constant VRF_REQUEST_CONFIRMATIONS_FIELD = "vrfRequestConfirmations";

    ValidationHarness internal harness;
    RoundConfigurationPackingHarness private packingHarness;

    function setUp() public {
        harness = new ValidationHarness();
        packingHarness = new RoundConfigurationPackingHarness();
    }

    function test_BuybackShareAppendsWithoutReinterpretingLegacyPackedAllocation() public {
        uint256 packedLegacyAllocation = uint256(5_000) | (uint256(4_000) << 16) | (uint256(1_000) << 32);
        packingHarness.seedLegacyAllocation(packedLegacyAllocation);

        (uint16 winner, uint16 nft, uint16 treasury, uint16 buyback) = packingHarness.allocation();
        assertEq(winner, 5_000);
        assertEq(nft, 4_000);
        assertEq(treasury, 1_000);
        assertEq(buyback, 0);
    }

    function test_DefaultConstantsMatchApprovedEconomics() public pure {
        assertEq(CrottoConstants.BPS, 10_000);
        assertEq(CrottoConstants.RAY, 1e27);
        assertEq(CrottoConstants.GENESIS_TREASURY_SUPPLY, 10_000_000 ether);

        assertEq(CrottoConstants.INITIAL_LOTTERY_WINNER_SHARE_BPS, 5_000);
        assertEq(CrottoConstants.INITIAL_LOTTERY_NFT_SHARE_BPS, 3_000);
        assertEq(CrottoConstants.INITIAL_LOTTERY_BUYBACK_SHARE_BPS, 1_000);
        assertEq(CrottoConstants.INITIAL_LOTTERY_TREASURY_SHARE_BPS, 1_000);

        assertEq(CrottoConstants.INITIAL_ACTIVATION_BURN_SHARE_BPS, 2_500);
        assertEq(CrottoConstants.INITIAL_ACTIVATION_NFT_SHARE_BPS, 2_500);
        assertEq(CrottoConstants.INITIAL_ACTIVATION_TREASURY_SHARE_BPS, 5_000);

        assertEq(CrottoConstants.INITIAL_HOOK_INPUT_FEE_BPS, 50);
        assertEq(CrottoConstants.INITIAL_HOOK_OUTPUT_FEE_BPS, 50);
        assertEq(CrottoConstants.INITIAL_HOOK_POL_SHARE_BPS, 5_000);
        assertEq(CrottoConstants.INITIAL_HOOK_NFT_SHARE_BPS, 4_000);
        assertEq(CrottoConstants.INITIAL_HOOK_TREASURY_SHARE_BPS, 1_000);
        assertEq(CrottoConstants.INITIAL_BUYBACK_SLIPPAGE_BPS, 500);

        assertEq(CrottoConstants.PAUSE_TICKET_PURCHASES, 1);
        assertEq(CrottoConstants.PAUSE_NFT_ACTIVATIONS, 2);
        assertEq(CrottoConstants.PAUSE_VAULT_PURCHASES, 4);
        assertEq(CrottoConstants.ALL_PAUSE_FLAGS, 7);
    }

    function test_ApprovedConfigurationsValidate() public view {
        harness.validateImmutableConfiguration(_validImmutableConfiguration());
        harness.validateRoundConfiguration(_validRoundConfiguration());
        harness.validateRoundBuybackCapacity(_validRoundConfiguration(), 200);
        harness.validateBootstrapReachability(_validRoundConfiguration(), 40 ether);
        harness.validateBuybackConfiguration(_validBuybackConfiguration());
        harness.validateActivationConfiguration(_validActivationConfiguration(), 10_000);
        harness.validateHookConfiguration(_validHookConfiguration(), 200);
        harness.validateTreasuryReceiver(address(0x1007), _validImmutableConfiguration());
        harness.validatePauseFlags(CrottoConstants.ALL_PAUSE_FLAGS);
    }

    function test_RevertWhen_TreasuryReceiverIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroAddress.selector, TREASURY_RECEIVER_FIELD));
        harness.validateTreasuryReceiver(address(0), _validImmutableConfiguration());
    }

    function test_RevertWhen_TreasuryReceiverIsProtocolCustody() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibCrottoValidation.TreasuryReceiverIsProtocol.selector, address(harness))
        );
        harness.validateTreasuryReceiver(address(harness), _validImmutableConfiguration());
    }

    function test_RevertWhen_TreasuryReceiverIsProtocolSatellite() public {
        ImmutableConfiguration memory immutableConfiguration = _validImmutableConfiguration();
        address protocolSatellite = immutableConfiguration.activationToken;

        vm.expectRevert(
            abi.encodeWithSelector(LibCrottoValidation.TreasuryReceiverIsProtocol.selector, protocolSatellite)
        );
        harness.validateTreasuryReceiver(protocolSatellite, immutableConfiguration);
    }

    function test_RevertWhen_ImmutableAddressIsZero() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.canonicalHook = address(0);

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroAddress.selector, CANONICAL_HOOK_FIELD));
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_ImmutableEconomicValueIsZero() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.vaultPrice = 0;

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroValue.selector, VAULT_PRICE_FIELD));
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_VrfRequestParameterIsZero() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.vrfCallbackGasLimit = 0;
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroValue.selector, VRF_CALLBACK_GAS_LIMIT_FIELD));
        harness.validateImmutableConfiguration(configuration);

        configuration = _validImmutableConfiguration();
        configuration.vrfRequestConfirmations = 0;
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroValue.selector, VRF_REQUEST_CONFIRMATIONS_FIELD));
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_VaultBackingCanOverflowAtMaximumSupply() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.rewardNFTMaxSupply = 2;
        configuration.vaultPrice = type(uint256).max / 2 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.VaultBackingCapacityExceeded.selector,
                configuration.vaultPrice,
                configuration.rewardNFTMaxSupply
            )
        );
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_UniswapV4PoolManagerIsZero() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.uniswapV4PoolManager = address(0);

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroAddress.selector, UNISWAP_V4_POOL_MANAGER_FIELD));
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_CanonicalAssetsAreEqual() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.weth = configuration.activationToken;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCanonicalPool.InvalidCanonicalAssets.selector,
                configuration.activationToken,
                configuration.activationToken
            )
        );
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_CanonicalTickSpacingExceedsV4Bound() public {
        ImmutableConfiguration memory configuration = _validImmutableConfiguration();
        configuration.canonicalTickSpacing = int24(type(int16).max) + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.InvalidCanonicalTickSpacing.selector, configuration.canonicalTickSpacing
            )
        );
        harness.validateImmutableConfiguration(configuration);
    }

    function test_RevertWhen_PlayerRewardRateIsZero() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.playerRewardRate = 0;

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroValue.selector, PLAYER_REWARD_RATE_FIELD));
        harness.validateRoundConfiguration(configuration);
    }

    function test_MaximumPlayerRewardLiabilityValidates() public view {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketTarget = 2;
        configuration.ticketOperationsFee = 0.11 ether;
        configuration.playerRewardRate = type(uint256).max / 2;

        harness.validateRoundConfiguration(configuration);
    }

    function test_MaximumTicketPaymentQuoteValidates() public view {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketTarget = 2;
        configuration.ticketOperationsFee = 2;
        configuration.ticketPrice = type(uint256).max / 2 - 2;
        configuration.maxVrfCost = 1;
        configuration.requestCallerReward = 1;
        configuration.finalizationCallerReward = 1;

        harness.validateRoundConfiguration(configuration);
    }

    function test_RevertWhen_TicketPaymentQuoteExceedsCapacity() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketTarget = 2;
        configuration.ticketOperationsFee = 2;
        configuration.ticketPrice = type(uint256).max / 2 - 1;
        configuration.maxVrfCost = 1;
        configuration.requestCallerReward = 1;
        configuration.finalizationCallerReward = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.TicketPaymentCapacityExceeded.selector,
                configuration.ticketPrice,
                configuration.ticketOperationsFee,
                configuration.ticketTarget
            )
        );
        harness.validateRoundConfiguration(configuration);
    }

    function test_RevertWhen_PlayerRewardLiabilityExceedsCapacity() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketTarget = 2;
        configuration.playerRewardRate = type(uint256).max / 2 + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.PlayerRewardLiabilityCapacityExceeded.selector,
                configuration.playerRewardRate,
                configuration.ticketTarget
            )
        );
        harness.validateRoundConfiguration(configuration);
    }

    function test_RevertWhen_RoundAllocationDoesNotConserveValue() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.treasuryShareBps = 999;

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InvalidAllocation.selector, 9_999));
        harness.validateRoundConfiguration(configuration);
    }

    function test_RevertWhen_RoundOperationsFundingIsInsufficient() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketOperationsFee = 0.001 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.InsufficientRoundOperationsFunding.selector, 0.1 ether, 0.22 ether
            )
        );
        harness.validateRoundConfiguration(configuration);
    }

    function test_RevertWhen_BootstrapThresholdCannotBeReachedAtSellout() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();

        vm.expectRevert(
            abi.encodeWithSelector(LibCrottoValidation.BootstrapThresholdUnreachable.selector, 40 ether, 41 ether)
        );
        harness.validateBootstrapReachability(configuration, 41 ether);
    }

    function test_RevertWhen_PerPurchaseRoundingPreventsBootstrapReachability() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketPrice = 2;
        configuration.ticketTarget = 2;

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.BootstrapThresholdUnreachable.selector, 0, 1));
        harness.validateBootstrapReachability(configuration, 1);
    }

    function test_RevertWhen_ActivationCostsAreNotIncreasing() public {
        ActivationConfiguration memory configuration = _validActivationConfiguration();
        configuration.costs[1] = configuration.costs[0];

        vm.expectRevert(LibCrottoValidation.InvalidTierCosts.selector);
        harness.validateActivationConfiguration(configuration, 10_000);
    }

    function test_RevertWhen_ActivationWeightsAreNotIncreasing() public {
        ActivationConfiguration memory configuration = _validActivationConfiguration();
        configuration.destinationWeights[0] = 0;

        vm.expectRevert(LibCrottoValidation.InvalidTierWeights.selector);
        harness.validateActivationConfiguration(configuration, 10_000);
    }

    function test_MaximumActivationWeightAtAggregateCapacityValidates() public view {
        uint256 maximumSupply = 10_000;
        uint256 maximumWeight = type(uint256).max / maximumSupply;
        ActivationConfiguration memory configuration = _validActivationConfiguration();
        configuration.destinationWeights = [maximumWeight - 2, maximumWeight - 1, maximumWeight];

        harness.validateActivationConfiguration(configuration, maximumSupply);
    }

    function test_RevertWhen_ActivationWeightExceedsAggregateCapacity() public {
        uint256 maximumSupply = 10_000;
        uint256 excessiveWeight = type(uint256).max / maximumSupply + 1;
        ActivationConfiguration memory configuration = _validActivationConfiguration();
        configuration.destinationWeights = [excessiveWeight - 2, excessiveWeight - 1, excessiveWeight];

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.ActivationWeightCapacityExceeded.selector, excessiveWeight, maximumSupply
            )
        );
        harness.validateActivationConfiguration(configuration, maximumSupply);
    }

    function test_RevertWhen_HookFeeExceedsImmutableCeiling() public {
        HookConfiguration memory configuration = _validHookConfiguration();

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InvalidHookFeeCeiling.selector, 100, 99));
        harness.validateHookConfiguration(configuration, 99);
    }

    function test_RevertWhen_BuybackCannotProduceSpecifiedInput() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        configuration.ticketPrice = 9;

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InsufficientBuybackExecutionAmount.selector, 0, 200));
        harness.validateRoundBuybackCapacity(configuration, 200);
    }

    function test_RevertWhen_MaximumInputFeeConsumesTheBuybackBudget() public {
        RoundConfiguration memory configuration = _validRoundConfiguration();
        uint256 grossWeth = configuration.ticketPrice * configuration.buybackShareBps / CrottoConstants.BPS;

        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoValidation.InsufficientBuybackExecutionAmount.selector, grossWeth, uint16(CrottoConstants.BPS)
            )
        );
        harness.validateRoundBuybackCapacity(configuration, CrottoConstants.BPS);
    }

    function test_RevertWhen_BuybackSlippageIsZeroOrComplete() public {
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InvalidBuybackSlippage.selector, 0));
        harness.validateBuybackConfiguration(BuybackConfiguration({slippageBps: 0}));

        vm.expectRevert(
            abi.encodeWithSelector(LibCrottoValidation.InvalidBuybackSlippage.selector, CrottoConstants.BPS)
        );
        harness.validateBuybackConfiguration(BuybackConfiguration({slippageBps: uint16(CrottoConstants.BPS)}));
    }

    function test_RevertWhen_CanonicalSwapPauseBitIsUsed() public {
        uint256 invalidFlags = 1 << 3;

        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InvalidPauseFlags.selector, invalidFlags));
        harness.validatePauseFlags(invalidFlags);
    }

    function testFuzz_ConservedAllocationAlwaysValidates(uint256 first, uint256 second) public view {
        first = bound(first, 0, CrottoConstants.BPS);
        second = bound(second, 0, CrottoConstants.BPS - first);
        uint256 third = CrottoConstants.BPS - first - second;

        harness.validateAllocation(first, second, third);
    }

    function testFuzz_ConservedFourWayAllocationAlwaysValidates(uint256 first, uint256 second, uint256 third)
        public
        view
    {
        first = bound(first, 0, CrottoConstants.BPS);
        second = bound(second, 0, CrottoConstants.BPS - first);
        third = bound(third, 0, CrottoConstants.BPS - first - second);
        uint256 fourth = CrottoConstants.BPS - first - second - third;

        harness.validateFourWayAllocation(first, second, third, fourth);
    }

    function _validImmutableConfiguration() private pure returns (ImmutableConfiguration memory configuration) {
        configuration = ImmutableConfiguration({
            activationToken: address(0x1001),
            rewardNFT: address(0x1002),
            weth: address(0x1003),
            vrfWrapper: address(0x1004),
            uniswapV4PoolManager: address(0x1005),
            canonicalHook: address(0x1006),
            rewardNFTMaxSupply: 10_000,
            vaultPrice: 1_000 ether,
            requiredBootstrapWeth: 30 ether,
            initialTokenPerWethWad: 10_000 ether,
            maxCombinedHookFeeBps: 200,
            canonicalTickSpacing: 60,
            vrfCallbackGasLimit: 250_000,
            vrfRequestConfirmations: 3
        });
    }

    function _validRoundConfiguration() private pure returns (RoundConfiguration memory configuration) {
        configuration = RoundConfiguration({
            ticketPrice: 1 ether,
            ticketOperationsFee: 0.01 ether,
            playerRewardRate: 100 ether,
            ticketTarget: 100,
            maxVrfCost: 0.2 ether,
            vrfRetryDelay: 10 minutes,
            requestCallerReward: 0.01 ether,
            finalizationCallerReward: 0.01 ether,
            winnerShareBps: CrottoConstants.INITIAL_LOTTERY_WINNER_SHARE_BPS,
            nftShareBps: CrottoConstants.INITIAL_LOTTERY_NFT_SHARE_BPS,
            treasuryShareBps: CrottoConstants.INITIAL_LOTTERY_TREASURY_SHARE_BPS,
            buybackShareBps: CrottoConstants.INITIAL_LOTTERY_BUYBACK_SHARE_BPS
        });
    }

    function _validActivationConfiguration() private pure returns (ActivationConfiguration memory configuration) {
        configuration.costs = [uint256(100 ether), 250 ether, 500 ether];
        configuration.destinationWeights = [uint256(1), 3, 10];
        configuration.burnShareBps = CrottoConstants.INITIAL_ACTIVATION_BURN_SHARE_BPS;
        configuration.nftShareBps = CrottoConstants.INITIAL_ACTIVATION_NFT_SHARE_BPS;
        configuration.treasuryShareBps = CrottoConstants.INITIAL_ACTIVATION_TREASURY_SHARE_BPS;
    }

    function _validHookConfiguration() private pure returns (HookConfiguration memory configuration) {
        configuration = HookConfiguration({
            inputFeeBps: CrottoConstants.INITIAL_HOOK_INPUT_FEE_BPS,
            outputFeeBps: CrottoConstants.INITIAL_HOOK_OUTPUT_FEE_BPS,
            polShareBps: CrottoConstants.INITIAL_HOOK_POL_SHARE_BPS,
            nftShareBps: CrottoConstants.INITIAL_HOOK_NFT_SHARE_BPS,
            treasuryShareBps: CrottoConstants.INITIAL_HOOK_TREASURY_SHARE_BPS
        });
    }

    function _validBuybackConfiguration() private pure returns (BuybackConfiguration memory configuration) {
        configuration.slippageBps = CrottoConstants.INITIAL_BUYBACK_SLIPPAGE_BPS;
    }
}
