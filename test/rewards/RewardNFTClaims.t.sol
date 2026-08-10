// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {RewardActivationFacet} from "../../src/diamond/facets/RewardActivationFacet.sol";
import {RewardClaimsFacet} from "../../src/diamond/facets/RewardClaimsFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibCrottoGuard} from "../../src/libraries/LibCrottoGuard.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";
import {ActivationConfiguration, NFTRewardPosition} from "../../src/types/CrottoTypes.sol";
import {RewardAssetMock, TransferRejectingRewardAsset} from "./RewardNFTIndexes.t.sol";

interface IRewardClaimsHarness is ICrottoRewards {
    function configureLifecycle(
        address activationToken,
        address rewardNft,
        address weth,
        address treasuryReceiver,
        ActivationConfiguration calldata configuration
    ) external;

    function mintRewardNFT(address receiver) external returns (uint256 tokenId);

    function accrueWeth(uint256 amount) external;

    function accrueToken(uint256 amount) external;

    function setAllPaused(bool paused) external;

    function scopedTransfer(address from, address to, uint256 tokenId) external;
}

contract RewardClaimsHarnessFacet is CrottoFacet {
    function configureLifecycle(
        address activationToken,
        address rewardNft,
        address weth,
        address treasuryReceiver,
        ActivationConfiguration calldata configuration
    ) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.immutableConfiguration.activationToken = activationToken;
        state.immutableConfiguration.rewardNFT = rewardNft;
        state.immutableConfiguration.weth = weth;
        state.activationConfiguration = configuration;
        state.activationConfigurationVersion = 1;
        state.treasuryReceiver = treasuryReceiver;
        state.immutableConfigurationInitialized = true;
    }

    function mintRewardNFT(address receiver) external returns (uint256 tokenId) {
        IRewardNFT rewardNft = IRewardNFT(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT);
        tokenId = rewardNft.mintedSupply() + 1;
        _checkpointNftRewards(tokenId);
        uint256 mintedTokenId = rewardNft.mint(receiver);
        assert(mintedTokenId == tokenId);
    }

    function accrueWeth(uint256 amount) external {
        _accrueNftWethRewards(amount);
    }

    function accrueToken(uint256 amount) external {
        _accrueNftTokenRewards(amount);
    }

    function setAllPaused(bool paused) external {
        LibGovernanceStorage.layout().pausedActions = paused ? CrottoConstants.ALL_PAUSE_FLAGS : 0;
    }

    function scopedTransfer(address from, address to, uint256 tokenId) external nonReentrant {
        _beginRewardNFTTransfer(from, to, tokenId);
        IRewardNFT(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT).transferFrom(from, to, tokenId);
        _finishRewardNFTTransfer();
    }
}

contract RewardNFTClaimsTest is Test {
    address private owner = makeAddr("owner");
    address private genesisTreasury = makeAddr("genesisTreasury");
    address private treasury = makeAddr("treasury");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private receiver = makeAddr("receiver");
    address private hook = makeAddr("hook");

    CrottoDiamond private diamond;
    RewardNFT private rewardNft;
    ActivationToken private token;
    RewardAssetMock private weth;
    IRewardClaimsHarness private rewards;

    function setUp() public {
        diamond = _deployCoreDiamond();
        rewardNft = new RewardNFT(address(diamond), 10);
        token = new ActivationToken(genesisTreasury, address(diamond), hook);
        weth = new RewardAssetMock("Wrapped Ether", "WETH");
        _installRewardFacets();

        rewards = IRewardClaimsHarness(address(diamond));
        rewards.configureLifecycle(address(token), address(rewardNft), address(weth), treasury, _configuration());

        vm.prank(genesisTreasury);
        assertTrue(token.transfer(alice, 2_000 ether));
        vm.prank(genesisTreasury);
        assertTrue(token.transfer(bob, 2_000 ether));
        vm.prank(alice);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(bob);
        token.approve(address(diamond), type(uint256).max);
    }

    function test_ClaimsEachAssetIndependentlyWithoutChangingActivation() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(10 ether, 20 ether);

        vm.prank(alice);
        uint256 wethAmount = rewards.claimNFTWethReward(tokenId, receiver);

        NFTRewardPosition memory afterWeth = rewards.nftRewardPosition(tokenId);
        assertEq(wethAmount, 10 ether);
        assertEq(weth.balanceOf(receiver), 10 ether);
        assertEq(afterWeth.claimableWeth, 0);
        assertEq(afterWeth.claimableToken, 20 ether);
        assertEq(afterWeth.tier, 1);
        assertEq(afterWeth.storedWeight, 1);

        vm.prank(alice);
        uint256 tokenAmount = rewards.claimNFTTokenReward(tokenId, receiver);
        NFTRewardPosition memory afterToken = rewards.nftRewardPosition(tokenId);
        assertEq(tokenAmount, 20 ether);
        assertEq(token.balanceOf(receiver), 20 ether);
        assertEq(afterToken.claimableToken, 0);
        assertEq(afterToken.tier, 1);
        assertEq(afterToken.storedWeight, 1);
        assertEq(rewards.wethRewardBook().totalClaimable, 0);
        assertEq(rewards.tokenRewardBook().totalClaimable, 0);
    }

    function test_TransferSettlesResetsAndMovesAttachedClaimsToNewOwner() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(12 ether, 24 ether);

        vm.prank(alice);
        rewardNft.transferFrom(alice, bob, tokenId);

        NFTRewardPosition memory position = rewards.nftRewardPosition(tokenId);
        assertEq(rewardNft.ownerOf(tokenId), bob);
        assertEq(position.tier, 0);
        assertEq(position.storedWeight, 0);
        assertEq(position.claimableWeth, 12 ether);
        assertEq(position.claimableToken, 24 ether);
        assertEq(rewards.totalActiveWeight(), 0);

        vm.prank(bob);
        rewards.claimNFTWethReward(tokenId, bob);
        vm.prank(bob);
        rewards.claimNFTTokenReward(tokenId, bob);
        assertEq(weth.balanceOf(bob), 12 ether);
        assertEq(token.balanceOf(bob), 2_024 ether);
    }

    function test_TransferRemovesWeightOnlyOnceAndPreservesClaims() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(9 ether, 9 ether);

        vm.prank(alice);
        rewardNft.transferFrom(alice, bob, tokenId);
        vm.prank(bob);
        rewardNft.transferFrom(bob, alice, tokenId);

        NFTRewardPosition memory position = rewards.nftRewardPosition(tokenId);
        assertEq(rewards.totalActiveWeight(), 0);
        assertEq(position.claimableWeth, 9 ether);
        assertEq(position.claimableToken, 9 ether);
    }

    function test_VaultStyleScopedTransfersUseSameResetAndClaimSemantics() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(7 ether, 11 ether);
        vm.prank(alice);
        rewardNft.approve(address(diamond), tokenId);

        rewards.scopedTransfer(alice, address(diamond), tokenId);
        rewards.scopedTransfer(address(diamond), bob, tokenId);

        NFTRewardPosition memory position = rewards.nftRewardPosition(tokenId);
        assertEq(rewardNft.ownerOf(tokenId), bob);
        assertEq(position.tier, 0);
        assertEq(position.storedWeight, 0);
        assertEq(position.claimableWeth, 7 ether);
        assertEq(position.claimableToken, 11 ether);
    }

    function test_InactiveNFTCanClaimPreviouslyAccruedRewards() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(5 ether, 0);
        vm.prank(alice);
        rewardNft.transferFrom(alice, bob, tokenId);

        vm.prank(bob);
        uint256 amount = rewards.claimNFTWethReward(tokenId, receiver);
        assertEq(amount, 5 ether);
        assertEq(weth.balanceOf(receiver), 5 ether);
    }

    function test_ZeroClaimSettlesAndReturnsZero() public {
        uint256 tokenId = rewards.mintRewardNFT(alice);
        vm.prank(alice);
        uint256 amount = rewards.claimNFTWethReward(tokenId, receiver);

        assertEq(amount, 0);
        assertEq(weth.balanceOf(receiver), 0);
        assertEq(rewards.nftRewardPosition(tokenId).tier, 0);
    }

    function test_ClaimsRemainAvailableUnderEveryGuardianPause() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(3 ether, 4 ether);
        rewards.setAllPaused(true);

        vm.prank(alice);
        rewards.claimNFTWethReward(tokenId, receiver);
        vm.prank(alice);
        rewards.claimNFTTokenReward(tokenId, receiver);
        assertEq(weth.balanceOf(receiver), 3 ether);
        assertEq(token.balanceOf(receiver), 4 ether);
    }

    function test_RevertWhen_ClaimCallerIsNotCurrentOwner() public {
        uint256 tokenId = rewards.mintRewardNFT(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardClaimsFacet.NotRewardNFTOwner.selector, tokenId, bob, alice));
        vm.prank(bob);
        rewards.claimNFTWethReward(tokenId, receiver);
    }

    function test_RevertWhen_ClaimReceiverIsZero() public {
        uint256 tokenId = rewards.mintRewardNFT(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardClaimsFacet.InvalidRewardReceiver.selector, address(0)));
        vm.prank(alice);
        rewards.claimNFTTokenReward(tokenId, address(0));
    }

    function test_RevertWhen_ClaimReceiverIsProtocolCustody() public {
        uint256 tokenId = _mintAndActivate(alice);
        _fundRewards(1 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(RewardClaimsFacet.InvalidRewardReceiver.selector, address(diamond)));
        vm.prank(alice);
        rewards.claimNFTWethReward(tokenId, address(diamond));

        (uint256 pendingWeth,) = rewards.pendingNFTRewards(tokenId);
        assertEq(pendingWeth, 1 ether);
    }

    function test_RevertWhen_UntrustedCallerInvokesTransferCallback() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCrottoGuard.UnauthorizedRewardNFTCallback.selector, address(this), address(rewardNft)
            )
        );
        rewards.onRewardNFTTransfer(alice, bob, 1);
    }

    function test_ClaimTransferFailureRestoresSelectedLiability() public {
        TransferRejectingRewardAsset rejectingWeth = new TransferRejectingRewardAsset();
        rewards.configureLifecycle(
            address(token), address(rewardNft), address(rejectingWeth), treasury, _configuration()
        );
        uint256 tokenId = _mintAndActivate(alice);
        rejectingWeth.mint(address(diamond), 8 ether);
        rewards.accrueWeth(8 ether);
        rejectingWeth.setRejectedReceiver(receiver);

        vm.expectRevert(abi.encodeWithSelector(TransferRejectingRewardAsset.RejectedReceiver.selector, receiver));
        vm.prank(alice);
        rewards.claimNFTWethReward(tokenId, receiver);

        (uint256 pendingWeth,) = rewards.pendingNFTRewards(tokenId);
        assertEq(pendingWeth, 8 ether);
        assertEq(rewards.wethRewardBook().totalClaimable, 0);
        assertEq(rejectingWeth.balanceOf(address(diamond)), 8 ether);
    }

    function _mintAndActivate(address nftOwner) private returns (uint256 tokenId) {
        tokenId = rewards.mintRewardNFT(nftOwner);
        vm.prank(nftOwner);
        rewards.activateNextTier(tokenId, 1, 100 ether);
    }

    function _fundRewards(uint256 wethAmount, uint256 tokenAmount) private {
        if (wethAmount != 0) {
            weth.mint(address(diamond), wethAmount);
            rewards.accrueWeth(wethAmount);
        }
        if (tokenAmount != 0) {
            vm.prank(genesisTreasury);
            assertTrue(token.transfer(address(diamond), tokenAmount));
            rewards.accrueToken(tokenAmount);
        }
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
        RewardActivationFacet activationFacet = new RewardActivationFacet();
        RewardClaimsFacet claimsFacet = new RewardClaimsFacet();
        RewardAccountingFacet accountingFacet = new RewardAccountingFacet();
        RewardClaimsHarnessFacet harnessFacet = new RewardClaimsHarnessFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _facetCut(address(activationFacet), _activationSelectors());
        cuts[1] = _facetCut(address(claimsFacet), _claimSelectors());
        cuts[2] = _facetCut(address(accountingFacet), _accountingSelectors());
        cuts[3] = _facetCut(address(harnessFacet), _harnessSelectors());
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
        selectors = new bytes4[](1);
        selectors[0] = RewardActivationFacet.activateNextTier.selector;
    }

    function _claimSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = RewardClaimsFacet.claimNFTWethReward.selector;
        selectors[1] = RewardClaimsFacet.claimNFTTokenReward.selector;
        selectors[2] = RewardClaimsFacet.onRewardNFTTransfer.selector;
    }

    function _accountingSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = RewardAccountingFacet.totalActiveWeight.selector;
        selectors[1] = RewardAccountingFacet.wethRewardBook.selector;
        selectors[2] = RewardAccountingFacet.tokenRewardBook.selector;
        selectors[3] = RewardAccountingFacet.nftRewardPosition.selector;
        selectors[4] = RewardAccountingFacet.pendingNFTRewards.selector;
    }

    function _harnessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IRewardClaimsHarness.configureLifecycle.selector;
        selectors[1] = IRewardClaimsHarness.mintRewardNFT.selector;
        selectors[2] = IRewardClaimsHarness.accrueWeth.selector;
        selectors[3] = IRewardClaimsHarness.accrueToken.selector;
        selectors[4] = IRewardClaimsHarness.setAllPaused.selector;
        selectors[5] = IRewardClaimsHarness.scopedTransfer.selector;
    }
}
