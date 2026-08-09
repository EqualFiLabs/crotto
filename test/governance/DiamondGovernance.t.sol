// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {GovernanceFacet} from "../../src/diamond/facets/GovernanceFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";
import {CrottoTimelock} from "../../src/governance/CrottoTimelock.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {LibCrottoValidation} from "../../src/libraries/LibCrottoValidation.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {LibRewardsStorage} from "../../src/libraries/storage/LibRewardsStorage.sol";
import {
    ActivationConfiguration,
    GovernanceInitialization,
    HookConfiguration,
    ImmutableConfiguration,
    RoundConfiguration
} from "../../src/types/CrottoTypes.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";

contract GovernedHookProbe {
    error UnauthorizedDiamond(address caller, address expectedDiamond);
    error ConfigurationRejected();

    address public diamond;
    address public lastCaller;
    bool public rejectConfiguration;
    HookConfiguration private storedConfiguration;

    function bindDiamond(address diamond_) external {
        require(diamond == address(0));
        diamond = diamond_;
    }

    function setRejectConfiguration(bool reject) external {
        rejectConfiguration = reject;
    }

    function setHookConfiguration(HookConfiguration calldata newConfiguration) external {
        if (msg.sender != diamond) revert UnauthorizedDiamond(msg.sender, diamond);
        if (rejectConfiguration) revert ConfigurationRejected();
        lastCaller = msg.sender;
        storedConfiguration = newConfiguration;
    }

    function configuration() external view returns (HookConfiguration memory) {
        return storedConfiguration;
    }
}

contract GovernanceStateProbeFacet {
    function initialized() external view returns (bool) {
        return LibGovernanceStorage.layout().immutableConfigurationInitialized;
    }

    function immutableConfiguration() external view returns (ImmutableConfiguration memory) {
        return LibGovernanceStorage.layout().immutableConfiguration;
    }

    function roundConfiguration() external view returns (RoundConfiguration memory) {
        return LibGovernanceStorage.layout().roundConfiguration;
    }

    function activationConfiguration()
        external
        view
        returns (uint64 version, ActivationConfiguration memory configuration)
    {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        return (state.activationConfigurationVersion, state.activationConfiguration);
    }

    function hookConfiguration() external view returns (HookConfiguration memory) {
        return LibGovernanceStorage.layout().hookConfiguration;
    }

    function seedHistoricalRound(uint256 roundId, RoundConfiguration calldata configuration) external {
        LibLotteryStorage.layout().rounds[roundId].config = configuration;
    }

    function historicalRoundConfiguration(uint256 roundId) external view returns (RoundConfiguration memory) {
        return LibLotteryStorage.layout().rounds[roundId].config;
    }

    function seedStoredWeight(uint256 tokenId, uint256 weight) external {
        LibRewardsStorage.layout().positions[tokenId].storedWeight = weight;
    }

    function storedWeight(uint256 tokenId) external view returns (uint256) {
        return LibRewardsStorage.layout().positions[tokenId].storedWeight;
    }
}

contract PausedSurfaceProbeFacet is CrottoFacet {
    uint256 private constant COUNTER_SLOT = 0x71f5ff572c0d04c5920956419d0ee176d051952402f43b62c1cc1b94e7f06700;

    function buyTickets() external whenNotPaused(CrottoConstants.PAUSE_TICKET_PURCHASES) {
        _increment();
    }

    function activate() external whenNotPaused(CrottoConstants.PAUSE_NFT_ACTIVATIONS) {
        _increment();
    }

    function buyFromVault() external whenNotPaused(CrottoConstants.PAUSE_VAULT_PURCHASES) {
        _increment();
    }

    function swap() external {
        _increment();
    }

    function claim() external {
        _increment();
    }

    function redeem() external {
        _increment();
    }

    function donate() external {
        _increment();
    }

    function compound() external {
        _increment();
    }

    function counter() external view returns (uint256 value) {
        uint256 slot = COUNTER_SLOT;
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function _increment() private {
        uint256 slot = COUNTER_SLOT;
        assembly ("memory-safe") {
            sstore(slot, add(sload(slot), 1))
        }
    }
}

contract DiamondGovernanceTest is Test {
    address private proposer = makeAddr("proposer");
    address private executor = makeAddr("executor");
    address private guardian = makeAddr("guardian");
    address private nextGuardian = makeAddr("nextGuardian");
    address private treasury = makeAddr("treasury");
    address private nextTreasury = makeAddr("nextTreasury");
    address private stranger = makeAddr("stranger");

    CrottoTimelock private timelock;
    GovernedHookProbe private hook;
    CrottoDiamond private diamond;
    ICrottoGovernance private governance;
    GovernanceStateProbeFacet private stateProbe;
    PausedSurfaceProbeFacet private pauseProbe;
    GovernanceFacet private governanceImplementation;
    uint256 private operationNonce;

    function setUp() public {
        vm.chainId(31_337);
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new CrottoTimelock(proposers, executors, address(0));

        hook = new GovernedHookProbe();
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        governanceImplementation = new GovernanceFacet();
        GovernanceStateProbeFacet stateProbeImplementation = new GovernanceStateProbeFacet();
        PausedSurfaceProbeFacet pauseProbeImplementation = new PausedSurfaceProbeFacet();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](6);
        initialCut[0] = _facetCut(address(cutFacet), _cutSelectors());
        initialCut[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        initialCut[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        initialCut[3] = _facetCut(address(governanceImplementation), _governanceSelectors());
        initialCut[4] = _facetCut(address(stateProbeImplementation), _stateProbeSelectors());
        initialCut[5] = _facetCut(address(pauseProbeImplementation), _pauseProbeSelectors());

        GovernanceInitialization memory initialization = _validInitialization();
        diamond = new CrottoDiamond(
            address(timelock),
            initialCut,
            address(initializer),
            abi.encodeCall(CrottoDiamondInit.initializeGovernance, (initialization))
        );
        hook.bindDiamond(address(diamond));
        governance = ICrottoGovernance(address(diamond));
        stateProbe = GovernanceStateProbeFacet(address(diamond));
        pauseProbe = PausedSurfaceProbeFacet(address(diamond));
    }

    function test_InitializationAtomicallySetsGovernanceAndTimelockOwnership() public view {
        assertEq(IERC173(address(diamond)).owner(), address(timelock));
        assertTrue(stateProbe.initialized());
        assertEq(stateProbe.immutableConfiguration().canonicalHook, address(hook));
        assertEq(stateProbe.roundConfiguration().ticketTarget, 100);
        (uint64 version, ActivationConfiguration memory activation) = stateProbe.activationConfiguration();
        assertEq(version, 1);
        assertEq(activation.costs[0], 100 ether);
        assertEq(stateProbe.hookConfiguration().inputFeeBps, 50);
        assertEq(governance.treasuryReceiver(), treasury);
        assertEq(governance.guardian(), guardian);
        assertTrue(IERC165(address(diamond)).supportsInterface(type(ICrottoGovernance).interfaceId));
    }

    function test_AllGovernedSettersExecuteThroughTimelockAndApplyProspectively() public {
        RoundConfiguration memory originalRound = stateProbe.roundConfiguration();
        stateProbe.seedHistoricalRound(7, originalRound);
        stateProbe.seedStoredWeight(11, 99);

        RoundConfiguration memory nextRound = originalRound;
        nextRound.ticketTarget = 200;
        _executeThroughTimelock(address(diamond), abi.encodeCall(governance.setRoundConfiguration, (nextRound)));

        ActivationConfiguration memory nextActivation = _validActivationConfiguration();
        nextActivation.costs = [uint256(150 ether), 300 ether, 600 ether];
        nextActivation.destinationWeights = [uint256(10), 20, 30];
        _executeThroughTimelock(
            address(diamond), abi.encodeCall(governance.setActivationConfiguration, (nextActivation))
        );

        HookConfiguration memory nextHook = _validHookConfiguration();
        nextHook.inputFeeBps = 75;
        nextHook.outputFeeBps = 75;
        _executeThroughTimelock(address(diamond), abi.encodeCall(governance.setHookConfiguration, (nextHook)));
        _executeThroughTimelock(address(diamond), abi.encodeCall(governance.setTreasuryReceiver, (nextTreasury)));
        _executeThroughTimelock(address(diamond), abi.encodeCall(governance.setGuardian, (nextGuardian)));

        assertEq(stateProbe.roundConfiguration().ticketTarget, 200);
        assertEq(stateProbe.historicalRoundConfiguration(7).ticketTarget, 100);
        (uint64 version, ActivationConfiguration memory activation) = stateProbe.activationConfiguration();
        assertEq(version, 2);
        assertEq(activation.destinationWeights[0], 10);
        assertEq(stateProbe.storedWeight(11), 99);
        assertEq(stateProbe.hookConfiguration().inputFeeBps, 75);
        assertEq(hook.configuration().inputFeeBps, 75);
        assertEq(hook.lastCaller(), address(diamond));
        assertEq(governance.treasuryReceiver(), nextTreasury);
        assertEq(governance.guardian(), nextGuardian);
    }

    function test_RevertWhen_NonTimelockConfiguresDiamondOrHookDirectly() public {
        RoundConfiguration memory roundConfiguration = _validRoundConfiguration();
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, proposer, address(timelock)));
        governance.setRoundConfiguration(roundConfiguration);

        HookConfiguration memory hookConfiguration = _validHookConfiguration();
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(GovernedHookProbe.UnauthorizedDiamond.selector, proposer, address(diamond))
        );
        hook.setHookConfiguration(hookConfiguration);
    }

    function test_InvalidGovernanceUpdatesRevertWithoutChangingState() public {
        RoundConfiguration memory originalRound = stateProbe.roundConfiguration();
        RoundConfiguration memory invalidRound = originalRound;
        invalidRound.ticketOperationsFee = 1;
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(LibCrottoValidation.InsufficientRoundOperationsFunding.selector, 100, 0.7 ether)
        );
        governance.setRoundConfiguration(invalidRound);

        invalidRound = stateProbe.roundConfiguration();
        invalidRound.ticketTarget = 10;
        invalidRound.ticketOperationsFee = 0.07 ether;
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(LibCrottoValidation.BootstrapThresholdUnreachable.selector, 4 ether, 40 ether)
        );
        governance.setRoundConfiguration(invalidRound);

        ActivationConfiguration memory invalidActivation = _validActivationConfiguration();
        invalidActivation.costs[1] = invalidActivation.costs[0];
        vm.prank(address(timelock));
        vm.expectRevert(LibCrottoValidation.InvalidTierCosts.selector);
        governance.setActivationConfiguration(invalidActivation);

        HookConfiguration memory invalidHook = _validHookConfiguration();
        invalidHook.inputFeeBps = 151;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InvalidHookFeeCeiling.selector, 201, 200));
        governance.setHookConfiguration(invalidHook);

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.ZeroAddress.selector, bytes32("treasuryReceiver")));
        governance.setTreasuryReceiver(address(0));

        assertEq(stateProbe.roundConfiguration().ticketTarget, 100);
        (uint64 version,) = stateProbe.activationConfiguration();
        assertEq(version, 1);
        assertEq(stateProbe.hookConfiguration().inputFeeBps, 50);
        assertEq(governance.treasuryReceiver(), treasury);
    }

    function test_HookRejectionRollsBackDiamondConfiguration() public {
        HookConfiguration memory accepted = _validHookConfiguration();
        accepted.inputFeeBps = 60;
        _executeThroughTimelock(address(diamond), abi.encodeCall(governance.setHookConfiguration, (accepted)));

        HookConfiguration memory rejected = accepted;
        rejected.outputFeeBps = 70;
        hook.setRejectConfiguration(true);

        vm.prank(address(timelock));
        vm.expectRevert(GovernedHookProbe.ConfigurationRejected.selector);
        governance.setHookConfiguration(rejected);

        assertEq(stateProbe.hookConfiguration().outputFeeBps, 50);
        assertEq(hook.configuration().outputFeeBps, 50);
    }

    function test_GuardianCanOnlyPauseApprovedActionsAndOnlyTimelockCanUnpause() public {
        vm.prank(guardian);
        governance.pauseActions(CrottoConstants.PAUSE_TICKET_PURCHASES | CrottoConstants.PAUSE_NFT_ACTIVATIONS);
        assertEq(
            governance.pausedActions(), CrottoConstants.PAUSE_TICKET_PURCHASES | CrottoConstants.PAUSE_NFT_ACTIVATIONS
        );

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, guardian, address(timelock)));
        governance.unpauseActions(CrottoConstants.PAUSE_TICKET_PURCHASES);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(LibCrottoValidation.InvalidPauseFlags.selector, 1 << 3));
        governance.pauseActions(1 << 3);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GovernanceFacet.NotGuardianOrOwner.selector, stranger));
        governance.pauseActions(CrottoConstants.PAUSE_VAULT_PURCHASES);

        vm.prank(address(timelock));
        governance.unpauseActions(CrottoConstants.PAUSE_TICKET_PURCHASES);
        assertEq(governance.pausedActions(), CrottoConstants.PAUSE_NFT_ACTIVATIONS);

        vm.prank(address(timelock));
        governance.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(GovernanceFacet.NotGuardianOrOwner.selector, guardian));
        governance.pauseActions(CrottoConstants.PAUSE_VAULT_PURCHASES);
    }

    function test_PausesOnlyTicketActivationAndVaultPurchaseEntryPoints() public {
        vm.prank(guardian);
        governance.pauseActions(CrottoConstants.ALL_PAUSE_FLAGS);

        vm.expectRevert(
            abi.encodeWithSelector(CrottoFacet.ActionPaused.selector, CrottoConstants.PAUSE_TICKET_PURCHASES)
        );
        pauseProbe.buyTickets();
        vm.expectRevert(
            abi.encodeWithSelector(CrottoFacet.ActionPaused.selector, CrottoConstants.PAUSE_NFT_ACTIVATIONS)
        );
        pauseProbe.activate();
        vm.expectRevert(
            abi.encodeWithSelector(CrottoFacet.ActionPaused.selector, CrottoConstants.PAUSE_VAULT_PURCHASES)
        );
        pauseProbe.buyFromVault();

        pauseProbe.swap();
        pauseProbe.claim();
        pauseProbe.redeem();
        pauseProbe.donate();
        pauseProbe.compound();
        assertEq(pauseProbe.counter(), 5);
    }

    function test_GovernanceInterfaceSupportTracksInstalledSelectors() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ICrottoGovernance.setGuardian.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: selectors
        });
        _executeThroughTimelock(address(diamond), abi.encodeCall(IDiamondCut.diamondCut, (cut, address(0), bytes(""))));
        assertFalse(IERC165(address(diamond)).supportsInterface(type(ICrottoGovernance).interfaceId));

        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(governanceImplementation),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
        _executeThroughTimelock(address(diamond), abi.encodeCall(IDiamondCut.diamondCut, (cut, address(0), bytes(""))));
        assertTrue(IERC165(address(diamond)).supportsInterface(type(ICrottoGovernance).interfaceId));
    }
    function _executeThroughTimelock(address target, bytes memory payload) private {
        bytes32 salt = bytes32(++operationNonce);
        uint256 delay = timelock.getMinDelay();
        vm.prank(proposer);
        timelock.schedule(target, 0, payload, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(executor);
        timelock.execute(target, 0, payload, bytes32(0), salt);
    }

    function _validInitialization() private view returns (GovernanceInitialization memory initialization) {
        initialization = GovernanceInitialization({
            immutableConfiguration: ImmutableConfiguration({
                activationToken: address(0x1001),
                rewardNFT: address(0x1002),
                weth: address(0x1003),
                vrfWrapper: address(0x1004),
                uniswapV4PoolManager: address(0x1005),
                canonicalHook: address(hook),
                rewardNFTMaxSupply: 10_000,
                vaultPrice: 1_000 ether,
                requiredBootstrapWeth: 40 ether,
                initialTokenPerWethWad: 10_000 ether,
                maxCombinedHookFeeBps: 200,
                canonicalTickSpacing: 60
            }),
            roundConfiguration: _validRoundConfiguration(),
            activationConfiguration: _validActivationConfiguration(),
            hookConfiguration: _validHookConfiguration(),
            treasuryReceiver: treasury,
            guardian: guardian
        });
    }

    function _validRoundConfiguration() private pure returns (RoundConfiguration memory configuration) {
        configuration = RoundConfiguration({
            ticketPrice: 1 ether,
            ticketOperationsFee: 0.01 ether,
            playerRewardRate: 10 ether,
            ticketTarget: 100,
            maxVrfCost: 0.5 ether,
            vrfRetryDelay: 10 minutes,
            requestCallerReward: 0.1 ether,
            finalizationCallerReward: 0.1 ether,
            winnerShareBps: 5_000,
            nftShareBps: 4_000,
            treasuryShareBps: 1_000
        });
    }

    function _validActivationConfiguration() private pure returns (ActivationConfiguration memory configuration) {
        configuration = ActivationConfiguration({
            costs: [uint256(100 ether), 200 ether, 300 ether],
            destinationWeights: [uint256(1), 2, 3],
            burnShareBps: 2_500,
            nftShareBps: 2_500,
            treasuryShareBps: 5_000
        });
    }

    function _validHookConfiguration() private pure returns (HookConfiguration memory configuration) {
        configuration = HookConfiguration({
            inputFeeBps: 50, outputFeeBps: 50, polShareBps: 5_000, nftShareBps: 4_000, treasuryShareBps: 1_000
        });
    }

    function _facetCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _cutSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = IERC165.supportsInterface.selector;
    }

    function _ownershipSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
    }

    function _governanceSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = ICrottoGovernance.setRoundConfiguration.selector;
        selectors[1] = ICrottoGovernance.setActivationConfiguration.selector;
        selectors[2] = ICrottoGovernance.setHookConfiguration.selector;
        selectors[3] = ICrottoGovernance.setTreasuryReceiver.selector;
        selectors[4] = ICrottoGovernance.setGuardian.selector;
        selectors[5] = ICrottoGovernance.pauseActions.selector;
        selectors[6] = ICrottoGovernance.unpauseActions.selector;
        selectors[7] = ICrottoGovernance.treasuryReceiver.selector;
        selectors[8] = ICrottoGovernance.guardian.selector;
        selectors[9] = ICrottoGovernance.pausedActions.selector;
    }

    function _stateProbeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = GovernanceStateProbeFacet.initialized.selector;
        selectors[1] = GovernanceStateProbeFacet.immutableConfiguration.selector;
        selectors[2] = GovernanceStateProbeFacet.roundConfiguration.selector;
        selectors[3] = GovernanceStateProbeFacet.activationConfiguration.selector;
        selectors[4] = GovernanceStateProbeFacet.hookConfiguration.selector;
        selectors[5] = GovernanceStateProbeFacet.seedHistoricalRound.selector;
        selectors[6] = GovernanceStateProbeFacet.historicalRoundConfiguration.selector;
        selectors[7] = GovernanceStateProbeFacet.seedStoredWeight.selector;
        selectors[8] = GovernanceStateProbeFacet.storedWeight.selector;
    }

    function _pauseProbeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = PausedSurfaceProbeFacet.buyTickets.selector;
        selectors[1] = PausedSurfaceProbeFacet.activate.selector;
        selectors[2] = PausedSurfaceProbeFacet.buyFromVault.selector;
        selectors[3] = PausedSurfaceProbeFacet.swap.selector;
        selectors[4] = PausedSurfaceProbeFacet.claim.selector;
        selectors[5] = PausedSurfaceProbeFacet.redeem.selector;
        selectors[6] = PausedSurfaceProbeFacet.donate.selector;
        selectors[7] = PausedSurfaceProbeFacet.compound.selector;
        selectors[8] = PausedSurfaceProbeFacet.counter.selector;
    }
}
