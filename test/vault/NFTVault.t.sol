// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {NFTVaultFacet} from "../../src/diamond/facets/NFTVaultFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {RewardActivationFacet} from "../../src/diamond/facets/RewardActivationFacet.sol";
import {RewardClaimsFacet} from "../../src/diamond/facets/RewardClaimsFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {INFTVault} from "../../src/interfaces/INFTVault.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../src/libraries/LibAssetTransfer.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";
import {ActivationConfiguration, NFTRewardPosition, VaultAccountingView} from "../../src/types/CrottoTypes.sol";
import {RewardAssetMock} from "../rewards/RewardNFTIndexes.t.sol";

interface INFTVaultHarness is INFTVault, ICrottoRewards {
    function configureVault(
        address activationToken,
        address rewardNft,
        address weth,
        address treasuryReceiver,
        uint256 maximumSupply,
        uint256 price,
        ActivationConfiguration calldata activationConfiguration
    ) external;

    function routeTokenReward(uint256 amount) external;

    function setVaultPurchasesPaused(bool paused) external;
}

contract NFTVaultHarnessFacet is CrottoFacet {
    function configureVault(
        address activationToken,
        address rewardNft,
        address weth,
        address treasuryReceiver,
        uint256 maximumSupply,
        uint256 price,
        ActivationConfiguration calldata activationConfiguration
    ) external {
        LibGovernanceStorage.Layout storage state = LibGovernanceStorage.layout();
        state.immutableConfiguration.activationToken = activationToken;
        state.immutableConfiguration.rewardNFT = rewardNft;
        state.immutableConfiguration.weth = weth;
        state.immutableConfiguration.rewardNFTMaxSupply = maximumSupply;
        state.immutableConfiguration.vaultPrice = price;
        state.activationConfiguration = activationConfiguration;
        state.activationConfigurationVersion = 1;
        state.treasuryReceiver = treasuryReceiver;
        state.immutableConfigurationInitialized = true;
    }

    function routeTokenReward(uint256 amount) external nonReentrant {
        address token = LibGovernanceStorage.layout().immutableConfiguration.activationToken;
        LibAssetTransfer.pullExact(token, msg.sender, amount);
        _accrueNftTokenRewards(amount);
    }

    function setVaultPurchasesPaused(bool paused) external {
        LibGovernanceStorage.layout().pausedActions = paused ? CrottoConstants.PAUSE_VAULT_PURCHASES : 0;
    }
}

contract NFTVaultTest is Test {
    uint256 private constant MAXIMUM_SUPPLY = 3;
    uint256 private constant PRICE = 100 ether;

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
    INFTVaultHarness private vault;

    function setUp() public {
        diamond = _deployCoreDiamond();
        rewardNft = new RewardNFT(address(diamond), MAXIMUM_SUPPLY);
        token = new ActivationToken(genesisTreasury, address(diamond), hook);
        weth = new RewardAssetMock("Wrapped Ether", "WETH");
        _installFacets();

        vault = INFTVaultHarness(address(diamond));
        vault.configureVault(
            address(token),
            address(rewardNft),
            address(weth),
            treasury,
            MAXIMUM_SUPPLY,
            PRICE,
            _activationConfiguration()
        );

        vm.startPrank(genesisTreasury);
        assertTrue(token.transfer(alice, 5_000 ether));
        assertTrue(token.transfer(bob, 5_000 ether));
        vm.stopPrank();
        vm.prank(alice);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(bob);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(genesisTreasury);
        token.approve(address(diamond), type(uint256).max);
    }

    function test_LazyMintPullsExactPriceAndInitializesRewardPosition() public {
        vm.expectEmit(true, true, false, true, address(diamond));
        emit INFTVault.RewardNFTMinted(1, alice);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit INFTVault.VaultNFTPurchased(alice, alice, 1, PRICE);
        vm.prank(alice);
        uint256 tokenId = vault.buyNewRewardNFT(alice);

        VaultAccountingView memory accounting = vault.vaultAccounting();
        NFTRewardPosition memory position = vault.nftRewardPosition(tokenId);
        assertEq(tokenId, 1);
        assertEq(rewardNft.ownerOf(tokenId), alice);
        assertEq(token.balanceOf(alice), 5_000 ether - PRICE);
        assertEq(token.balanceOf(address(diamond)), PRICE);
        assertEq(accounting.mintedSupply, 1);
        assertEq(accounting.vaultInventory, 0);
        assertEq(accounting.circulatingNfts, 1);
        assertEq(accounting.vaultTokenBacking, PRICE);
        assertEq(accounting.requiredTokenBacking, PRICE);
        assertEq(position.tier, 0);
        assertEq(position.storedWeight, 0);
    }

    function test_LazyMintContinuesBeforeCapDespiteRedeemedInventory() public {
        uint256 first = _buyNew(alice);
        _approveAndRedeem(alice, first, alice);

        vm.prank(bob);
        uint256 second = vault.buyNewRewardNFT(bob);

        assertEq(second, 2);
        assertEq(rewardNft.ownerOf(first), address(diamond));
        assertEq(rewardNft.ownerOf(second), bob);
        assertEq(vault.vaultInventory(), 1);
        assertEq(vault.circulatingNFTs(), 1);
        assertEq(vault.vaultAccounting().vaultTokenBacking, PRICE);
        assertEq(vault.requiredVaultBacking(), PRICE);
    }

    function test_InventoryPurchasesBeginOnlyAtCapAndRejectEmptyInventory() public {
        uint256 first = _buyNew(alice);
        _approveAndRedeem(alice, first, alice);

        vm.expectRevert(abi.encodeWithSelector(NFTVaultFacet.RewardNFTMintingIncomplete.selector, 1, MAXIMUM_SUPPLY));
        vm.prank(bob);
        vault.buyInventoryRewardNFT(first, bob);

        _buyNew(alice);
        _buyNew(bob);
        vm.prank(bob);
        vault.buyInventoryRewardNFT(first, bob);
        assertEq(rewardNft.ownerOf(first), bob);

        vm.expectRevert(NFTVaultFacet.VaultInventoryEmpty.selector);
        vm.prank(alice);
        vault.buyInventoryRewardNFT(first, alice);
    }

    function test_RedemptionAndInventorySalePreserveAttachedClaims() public {
        uint256 tokenId = _buyNew(alice);
        vm.prank(alice);
        vault.activateNextTier(tokenId, 1, 10 ether);
        vm.prank(genesisTreasury);
        vault.routeTokenReward(20 ether);

        _approveAndRedeem(alice, tokenId, receiver);
        NFTRewardPosition memory redeemedPosition = vault.nftRewardPosition(tokenId);
        assertEq(rewardNft.ownerOf(tokenId), address(diamond));
        assertEq(redeemedPosition.tier, 0);
        assertEq(redeemedPosition.storedWeight, 0);
        assertEq(redeemedPosition.claimableToken, 20 ether);
        assertEq(token.balanceOf(receiver), PRICE);
        assertEq(vault.vaultAccounting().vaultTokenBacking, 0);
        assertEq(token.balanceOf(address(diamond)), 20 ether);

        _buyNew(alice);
        _buyNew(bob);
        vm.prank(bob);
        vault.buyInventoryRewardNFT(tokenId, bob);

        assertEq(vault.nftRewardPosition(tokenId).claimableToken, 20 ether);
        vm.prank(bob);
        vault.claimNFTTokenReward(tokenId, bob);
        assertEq(vault.vaultAccounting().vaultTokenBacking, PRICE * 3);
        assertEq(token.balanceOf(address(diamond)), PRICE * 3);
    }

    function test_RedemptionRemainsAvailableWhilePurchasesArePaused() public {
        uint256 tokenId = _buyNew(alice);
        vault.setVaultPurchasesPaused(true);

        vm.expectRevert(
            abi.encodeWithSelector(CrottoFacet.ActionPaused.selector, CrottoConstants.PAUSE_VAULT_PURCHASES)
        );
        vm.prank(bob);
        vault.buyNewRewardNFT(bob);

        _approveAndRedeem(alice, tokenId, receiver);
        assertEq(rewardNft.ownerOf(tokenId), address(diamond));
        assertEq(token.balanceOf(receiver), PRICE);
    }

    function test_DirectNftDonationOnlyOvercollateralizesBacking() public {
        uint256 tokenId = _buyNew(alice);
        vm.prank(alice);
        rewardNft.transferFrom(alice, address(diamond), tokenId);

        assertEq(vault.vaultAccounting().vaultTokenBacking, PRICE);
        assertEq(vault.requiredVaultBacking(), 0);

        _buyNew(bob);
        VaultAccountingView memory accounting = vault.vaultAccounting();
        assertEq(accounting.vaultTokenBacking, PRICE * 2);
        assertEq(accounting.requiredTokenBacking, PRICE);
        assertEq(accounting.vaultInventory, 1);
    }

    function test_DirectTokenDonationDoesNotEnterLogicalBacking() public {
        vm.prank(genesisTreasury);
        assertTrue(token.transfer(address(diamond), 7 ether));
        assertEq(vault.vaultAccounting().vaultTokenBacking, 0);

        _buyNew(alice);
        assertEq(vault.vaultAccounting().vaultTokenBacking, PRICE);
        assertEq(token.balanceOf(address(diamond)), PRICE + 7 ether);
    }

    function test_RevertWhen_SelectedTokenIsNotVaultInventory() public {
        uint256 first = _buyNew(alice);
        _buyNew(alice);
        _buyNew(bob);
        _approveAndRedeem(alice, first, alice);

        vm.expectRevert(abi.encodeWithSelector(NFTVaultFacet.RewardNFTNotInVault.selector, 2));
        vm.prank(bob);
        vault.buyInventoryRewardNFT(2, bob);
    }

    function test_RevertWhen_PurchaseAllowanceIsMissingWithoutChangingBacking() public {
        address carol = makeAddr("carol");
        vm.prank(genesisTreasury);
        assertTrue(token.transfer(carol, PRICE));

        vm.expectRevert();
        vm.prank(carol);
        vault.buyNewRewardNFT(carol);

        assertEq(rewardNft.mintedSupply(), 0);
        assertEq(vault.vaultAccounting().vaultTokenBacking, 0);
    }

    function test_RevertWhen_VaultReceiverIsProtocolCustody() public {
        vm.expectRevert(abi.encodeWithSelector(NFTVaultFacet.InvalidVaultReceiver.selector, address(diamond)));
        vm.prank(alice);
        vault.buyNewRewardNFT(address(diamond));

        uint256 tokenId = _buyNew(alice);
        vm.prank(alice);
        rewardNft.approve(address(diamond), tokenId);
        vm.expectRevert(abi.encodeWithSelector(NFTVaultFacet.InvalidVaultReceiver.selector, address(token)));
        vm.prank(alice);
        vault.redeemRewardNFT(tokenId, address(token));
        assertEq(rewardNft.ownerOf(tokenId), alice);
    }

    function test_ViewsHandleUnknownTokenAndCapNewMinting() public {
        assertFalse(vault.isVaultInventory(99));
        _buyNew(alice);
        _buyNew(alice);
        _buyNew(bob);

        vm.expectRevert(abi.encodeWithSelector(NFTVaultFacet.RewardNFTMintingComplete.selector, MAXIMUM_SUPPLY));
        vm.prank(alice);
        vault.buyNewRewardNFT(alice);
    }

    function _buyNew(address buyer) private returns (uint256 tokenId) {
        vm.prank(buyer);
        tokenId = vault.buyNewRewardNFT(buyer);
    }

    function _approveAndRedeem(address seller, uint256 tokenId, address payoutReceiver) private {
        vm.prank(seller);
        rewardNft.approve(address(diamond), tokenId);
        vm.prank(seller);
        vault.redeemRewardNFT(tokenId, payoutReceiver);
    }

    function _activationConfiguration() private pure returns (ActivationConfiguration memory configuration) {
        configuration = ActivationConfiguration({
            costs: [uint256(10 ether), 20 ether, 30 ether],
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

    function _installFacets() private {
        RewardActivationFacet activationFacet = new RewardActivationFacet();
        RewardClaimsFacet claimsFacet = new RewardClaimsFacet();
        RewardAccountingFacet accountingFacet = new RewardAccountingFacet();
        NFTVaultFacet vaultFacet = new NFTVaultFacet();
        NFTVaultHarnessFacet harnessFacet = new NFTVaultHarnessFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _facetCut(address(activationFacet), _activationSelectors());
        cuts[1] = _facetCut(address(claimsFacet), _claimSelectors());
        cuts[2] = _facetCut(address(accountingFacet), _accountingSelectors());
        cuts[3] = _facetCut(address(vaultFacet), _vaultSelectors());
        cuts[4] = _facetCut(address(harnessFacet), _harnessSelectors());
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

    function _vaultSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = NFTVaultFacet.buyNewRewardNFT.selector;
        selectors[1] = NFTVaultFacet.buyInventoryRewardNFT.selector;
        selectors[2] = NFTVaultFacet.redeemRewardNFT.selector;
        selectors[3] = NFTVaultFacet.vaultPrice.selector;
        selectors[4] = NFTVaultFacet.vaultInventory.selector;
        selectors[5] = NFTVaultFacet.circulatingNFTs.selector;
        selectors[6] = NFTVaultFacet.requiredVaultBacking.selector;
        selectors[7] = NFTVaultFacet.isVaultInventory.selector;
        selectors[8] = NFTVaultFacet.vaultAccounting.selector;
    }

    function _harnessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = INFTVaultHarness.configureVault.selector;
        selectors[1] = INFTVaultHarness.routeTokenReward.selector;
        selectors[2] = INFTVaultHarness.setVaultPurchasesPaused.selector;
    }
}
