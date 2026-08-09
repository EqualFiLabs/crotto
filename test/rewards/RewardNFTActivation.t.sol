// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {RewardActivationFacet} from "../../src/diamond/facets/RewardActivationFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../src/libraries/LibAssetTransfer.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";
import {ActivationConfiguration, NFTRewardPosition} from "../../src/types/CrottoTypes.sol";

interface IRewardActivationHarness is ICrottoRewards {
    function configureActivation(
        address activationToken,
        address rewardNft,
        address treasuryReceiver,
        ActivationConfiguration calldata configuration
    ) external;

    function setActivationConfiguration(ActivationConfiguration calldata configuration) external;

    function setActivationPaused(bool paused) external;

    function mintRewardNFT(address receiver) external returns (uint256 tokenId);
}

contract RewardActivationHarnessFacet is RewardActivationFacet {
    function configureActivation(
        address activationToken,
        address rewardNft,
        address treasuryReceiver,
        ActivationConfiguration calldata configuration
    ) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.immutableConfiguration.activationToken = activationToken;
        state.immutableConfiguration.rewardNFT = rewardNft;
        state.activationConfiguration = configuration;
        state.activationConfigurationVersion = 1;
        state.treasuryReceiver = treasuryReceiver;
        state.immutableConfigurationInitialized = true;
    }

    function setActivationConfiguration(ActivationConfiguration calldata configuration) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.activationConfiguration = configuration;
        ++state.activationConfigurationVersion;
    }

    function setActivationPaused(bool paused) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        if (paused) state.pausedActions |= CrottoConstants.PAUSE_NFT_ACTIVATIONS;
        else state.pausedActions &= ~CrottoConstants.PAUSE_NFT_ACTIVATIONS;
    }

    function mintRewardNFT(address receiver) external returns (uint256 tokenId) {
        IRewardNFT rewardNft = IRewardNFT(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT);
        tokenId = rewardNft.mintedSupply() + 1;
        _checkpointNftRewards(tokenId);
        uint256 mintedTokenId = rewardNft.mint(receiver);
        assert(mintedTokenId == tokenId);
    }
}

contract ConfigurableActivationAsset is ERC20 {
    uint256 private constant TRANSFER_FEE_BPS = 100;

    address public rejectedReceiver;
    bool public feeEnabled;

    constructor() ERC20("Activation Test", "ACT") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function setFeeEnabled(bool enabled) external {
        feeEnabled = enabled;
    }

    function setRejectedReceiver(address receiver) external {
        rejectedReceiver = receiver;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == rejectedReceiver) revert("REJECTED_RECEIVER");
        if (!feeEnabled || from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * TRANSFER_FEE_BPS / CrottoConstants.BPS;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract RewardNFTActivationTest is Test {
    address private owner = makeAddr("owner");
    address private genesisTreasury = makeAddr("genesisTreasury");
    address private treasury = makeAddr("treasury");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private hook = makeAddr("hook");

    CrottoDiamond private diamond;
    RewardNFT private rewardNft;
    ActivationToken private token;
    IRewardActivationHarness private activation;

    function setUp() public {
        diamond = _deployCoreDiamond();
        rewardNft = new RewardNFT(address(diamond), 10);
        token = new ActivationToken(genesisTreasury, address(diamond), hook);
        _installRewardFacets();

        activation = IRewardActivationHarness(address(diamond));
        activation.configureActivation(address(token), address(rewardNft), treasury, _configuration());

        vm.prank(genesisTreasury);
        assertTrue(token.transfer(alice, 2_000 ether));
        vm.prank(genesisTreasury);
        assertTrue(token.transfer(bob, 2_000 ether));
        vm.prank(alice);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(bob);
        token.approve(address(diamond), type(uint256).max);
    }

    function test_FirstActivationCannotEarnItsOwnPayment() public {
        uint256 tokenId = activation.mintRewardNFT(alice);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, false, false, true, address(diamond));
        emit ICrottoRewards.ActivationFeeRouted(tokenId, 25 ether, 0, 75 ether);
        vm.prank(alice);
        activation.activateNextTier(tokenId);

        NFTRewardPosition memory position = activation.nftRewardPosition(tokenId);
        assertEq(position.tier, 1);
        assertEq(position.storedWeight, 1);
        assertEq(position.claimableToken, 0);
        assertEq(activation.totalActiveWeight(), 1);
        assertEq(token.totalSupply(), supplyBefore - 25 ether);
        assertEq(token.balanceOf(treasury), 75 ether);
        assertEq(token.balanceOf(address(diamond)), 0);
    }

    function test_NewTierOneIndexesOnlyAcrossPreExistingWeight() public {
        uint256 first = activation.mintRewardNFT(alice);
        uint256 second = activation.mintRewardNFT(bob);
        vm.prank(alice);
        activation.activateNextTier(first);

        vm.prank(bob);
        activation.activateNextTier(second);

        (, uint256 firstPending) = activation.pendingNFTRewards(first);
        (, uint256 secondPending) = activation.pendingNFTRewards(second);
        assertEq(firstPending, 25 ether);
        assertEq(secondPending, 0);
        assertEq(token.balanceOf(treasury), 125 ether);
        assertEq(token.balanceOf(address(diamond)), 25 ether);
    }

    function test_UpgradeEarnsWithOldWeightBeforeNewWeightApplies() public {
        uint256 first = activation.mintRewardNFT(alice);
        uint256 second = activation.mintRewardNFT(bob);
        vm.prank(alice);
        activation.activateNextTier(first);
        vm.prank(bob);
        activation.activateNextTier(second);

        (, uint256 firstBefore) = activation.pendingNFTRewards(first);
        (, uint256 secondBefore) = activation.pendingNFTRewards(second);
        vm.prank(alice);
        activation.activateNextTier(first);

        (, uint256 firstAfter) = activation.pendingNFTRewards(first);
        (, uint256 secondAfter) = activation.pendingNFTRewards(second);
        assertEq(firstAfter - firstBefore, 25 ether);
        assertEq(secondAfter - secondBefore, 25 ether);
        assertEq(activation.nftRewardPosition(first).tier, 2);
        assertEq(activation.nftRewardPosition(first).storedWeight, 2);
        assertEq(activation.totalActiveWeight(), 3);
    }

    function test_GovernanceChangesAreProspectiveAndVersioned() public {
        uint256 tokenId = activation.mintRewardNFT(alice);
        vm.prank(alice);
        activation.activateNextTier(tokenId);

        ActivationConfiguration memory next = _configuration();
        next.costs = [uint256(125 ether), 250 ether, 400 ether];
        next.destinationWeights = [uint256(5), 7, 9];
        activation.setActivationConfiguration(next);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ICrottoRewards.NFTTierActivated(tokenId, 1, 2, 250 ether, 7, 2);
        vm.prank(alice);
        activation.activateNextTier(tokenId);

        NFTRewardPosition memory position = activation.nftRewardPosition(tokenId);
        assertEq(position.tier, 2);
        assertEq(position.storedWeight, 7);
    }

    function test_RoundingRemainderIsPaidToTreasury() public {
        ActivationConfiguration memory next = _configuration();
        next.costs = [uint256(101), 202, 303];
        activation.setActivationConfiguration(next);
        uint256 tokenId = activation.mintRewardNFT(alice);

        vm.prank(alice);
        activation.activateNextTier(tokenId);

        assertEq(token.balanceOf(treasury), 76);
        assertEq(token.balanceOf(address(diamond)), 0);
    }

    function test_RevertWhen_CallerDoesNotOwnRewardNFT() public {
        uint256 tokenId = activation.mintRewardNFT(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardActivationFacet.NotRewardNFTOwner.selector, tokenId, bob, alice));
        vm.prank(bob);
        activation.activateNextTier(tokenId);
    }

    function test_RevertWhen_AlreadyAtMaximumTier() public {
        uint256 tokenId = activation.mintRewardNFT(alice);
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            activation.activateNextTier(tokenId);
        }

        vm.expectRevert(abi.encodeWithSelector(RewardActivationFacet.MaximumTierReached.selector, tokenId));
        vm.prank(alice);
        activation.activateNextTier(tokenId);
    }

    function test_RevertWhen_ActivationsArePaused() public {
        uint256 tokenId = activation.mintRewardNFT(alice);
        activation.setActivationPaused(true);

        vm.expectRevert(abi.encodeWithSelector(CrottoFacet.ActionPaused.selector, uint256(2)));
        vm.prank(alice);
        activation.activateNextTier(tokenId);
    }

    function test_RevertWhen_TOKENReceiptIsNotExact() public {
        ConfigurableActivationAsset feeToken = new ConfigurableActivationAsset();
        feeToken.mint(alice, 1_000 ether);
        activation.configureActivation(address(feeToken), address(rewardNft), treasury, _configuration());
        vm.prank(alice);
        feeToken.approve(address(diamond), type(uint256).max);
        feeToken.setFeeEnabled(true);
        uint256 tokenId = activation.mintRewardNFT(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibAssetTransfer.UnexpectedTokenReceipt.selector,
                address(feeToken),
                address(diamond),
                100 ether,
                99 ether
            )
        );
        vm.prank(alice);
        activation.activateNextTier(tokenId);

        assertEq(activation.nftRewardPosition(tokenId).tier, 0);
        assertEq(feeToken.balanceOf(alice), 1_000 ether);
    }

    function test_TreasuryFailureRevertsCompleteActivation() public {
        ConfigurableActivationAsset rejectingToken = new ConfigurableActivationAsset();
        rejectingToken.mint(alice, 1_000 ether);
        activation.configureActivation(address(rejectingToken), address(rewardNft), treasury, _configuration());
        vm.prank(alice);
        rejectingToken.approve(address(diamond), type(uint256).max);
        rejectingToken.setRejectedReceiver(treasury);
        uint256 tokenId = activation.mintRewardNFT(alice);
        uint256 supplyBefore = rejectingToken.totalSupply();

        vm.expectRevert(bytes("REJECTED_RECEIVER"));
        vm.prank(alice);
        activation.activateNextTier(tokenId);

        assertEq(activation.nftRewardPosition(tokenId).tier, 0);
        assertEq(rejectingToken.totalSupply(), supplyBefore);
        assertEq(rejectingToken.balanceOf(alice), 1_000 ether);
        assertEq(rejectingToken.balanceOf(address(diamond)), 0);
    }

    function testFuzz_ActivationAllocationConservesPayment(uint256 cost) public {
        cost = bound(cost, 1, 1_000 ether);
        ActivationConfiguration memory next = _configuration();
        next.costs = [cost, cost + 1, cost + 2];
        activation.setActivationConfiguration(next);
        uint256 tokenId = activation.mintRewardNFT(alice);
        uint256 userBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        activation.activateNextTier(tokenId);

        uint256 burned = supplyBefore - token.totalSupply();
        assertEq(userBefore - token.balanceOf(alice), cost);
        assertEq(burned + token.balanceOf(treasury), cost);
        assertEq(token.balanceOf(address(diamond)), 0);
    }

    function _configuration() private pure returns (ActivationConfiguration memory configuration) {
        configuration = ActivationConfiguration({
            costs: [uint256(100 ether), 200 ether, 300 ether],
            destinationWeights: [uint256(1), 2, 3],
            burnShareBps: 2_500,
            nftShareBps: 2_500,
            treasuryShareBps: 5_000
        });
    }

    function _deployCoreDiamond() private returns (CrottoDiamond deployed) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](3);
        initialCut[0] = _facetCut(address(cutFacet), _cutSelectors());
        initialCut[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        initialCut[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        deployed = new CrottoDiamond(
            owner, initialCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function _installRewardFacets() private {
        RewardActivationHarnessFacet activationFacet = new RewardActivationHarnessFacet();
        RewardAccountingFacet accountingFacet = new RewardAccountingFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = _facetCut(address(activationFacet), _activationSelectors());
        cuts[1] = _facetCut(address(accountingFacet), _accountingSelectors());
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
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

    function _activationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = RewardActivationFacet.activateNextTier.selector;
        selectors[1] = IRewardActivationHarness.configureActivation.selector;
        selectors[2] = IRewardActivationHarness.setActivationConfiguration.selector;
        selectors[3] = IRewardActivationHarness.setActivationPaused.selector;
        selectors[4] = IRewardActivationHarness.mintRewardNFT.selector;
    }

    function _accountingSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = RewardAccountingFacet.totalActiveWeight.selector;
        selectors[1] = RewardAccountingFacet.wethRewardBook.selector;
        selectors[2] = RewardAccountingFacet.tokenRewardBook.selector;
        selectors[3] = RewardAccountingFacet.nftRewardPosition.selector;
        selectors[4] = RewardAccountingFacet.pendingNFTRewards.selector;
    }
}
