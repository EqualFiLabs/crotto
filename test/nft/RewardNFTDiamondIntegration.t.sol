// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";

interface IRewardNFTIntegrationHarness {
    function configureRewardNFT(address rewardNFT) external;

    function mintRewardNFT(address receiver) external returns (uint256 tokenId);

    function onRewardNFTTransfer(address from, address to, uint256 tokenId) external;

    function scopedTransfer(address from, address to, uint256 tokenId) external;

    function callbackRecord()
        external
        view
        returns (uint256 count, address from, address to, uint256 tokenId, address ownerDuringCallback);
}

library RewardNFTIntegrationStorage {
    bytes32 internal constant SLOT = keccak256("crotto.test.storage.RewardNFTIntegration");

    struct Layout {
        uint256 callbackCount;
        address from;
        address to;
        uint256 tokenId;
        address ownerDuringCallback;
    }

    function layout() internal pure returns (Layout storage state) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }
}

contract RewardNFTIntegrationFacet is CrottoFacet, IRewardNFTIntegrationHarness {
    function configureRewardNFT(address rewardNFT) external {
        // Synthetic setup is required until the complete deployment initializer exists.
        LibGovernanceStorage.layout().immutableConfiguration.rewardNFT = rewardNFT;
    }

    function mintRewardNFT(address receiver) external returns (uint256 tokenId) {
        return _rewardNft().mint(receiver);
    }

    function onRewardNFTTransfer(address from, address to, uint256 tokenId)
        external
        onlyRewardNFTTransferCallback(from, to, tokenId)
    {
        RewardNFTIntegrationStorage.Layout storage state = RewardNFTIntegrationStorage.layout();
        ++state.callbackCount;
        state.from = from;
        state.to = to;
        state.tokenId = tokenId;
        state.ownerDuringCallback = _rewardNft().ownerOf(tokenId);
    }

    function scopedTransfer(address from, address to, uint256 tokenId) external nonReentrant {
        _beginRewardNFTTransfer(from, to, tokenId);
        _rewardNft().transferFrom(from, to, tokenId);
        _finishRewardNFTTransfer();
    }

    function callbackRecord()
        external
        view
        returns (uint256 count, address from, address to, uint256 tokenId, address ownerDuringCallback)
    {
        RewardNFTIntegrationStorage.Layout storage state = RewardNFTIntegrationStorage.layout();
        return (state.callbackCount, state.from, state.to, state.tokenId, state.ownerDuringCallback);
    }

    function _rewardNft() private view returns (IRewardNFT) {
        return IRewardNFT(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT);
    }
}

contract RewardNFTDiamondIntegrationTest is Test {
    address private owner = makeAddr("owner");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    DiamondCutFacet private cutFacet;
    DiamondLoupeFacet private loupeFacet;
    OwnershipFacet private ownershipFacet;
    CrottoDiamondInit private initializer;
    RewardNFTIntegrationFacet private integrationFacet;
    CrottoDiamond private diamond;
    RewardNFT private rewardNFT;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        initializer = new CrottoDiamondInit();
        integrationFacet = new RewardNFTIntegrationFacet();

        diamond = _deployCoreDiamond();
        _installIntegrationFacet();
        rewardNFT = new RewardNFT(address(diamond), 10);
        IRewardNFTIntegrationHarness(address(diamond)).configureRewardNFT(address(rewardNFT));
    }

    function test_DirectUserTransferUsesAuthenticatedRootCallback() public {
        IRewardNFTIntegrationHarness(address(diamond)).mintRewardNFT(alice);

        vm.prank(alice);
        rewardNFT.transferFrom(alice, bob, 1);

        _assertCallback(1, alice, bob, 1, alice);
        assertEq(rewardNFT.ownerOf(1), bob);
    }

    function test_ScopedDiamondTransferConsumesExactCallbackContext() public {
        IRewardNFTIntegrationHarness(address(diamond)).mintRewardNFT(alice);
        vm.prank(alice);
        rewardNFT.approve(address(diamond), 1);

        IRewardNFTIntegrationHarness(address(diamond)).scopedTransfer(alice, address(diamond), 1);

        _assertCallback(1, alice, address(diamond), 1, alice);
        assertEq(rewardNFT.ownerOf(1), address(diamond));

        IRewardNFTIntegrationHarness(address(diamond)).scopedTransfer(address(diamond), bob, 1);

        _assertCallback(2, address(diamond), bob, 1, address(diamond));
        assertEq(rewardNFT.ownerOf(1), bob);
    }

    function _assertCallback(uint256 count, address from, address to, uint256 tokenId, address ownerDuring)
        private
        view
    {
        (uint256 actualCount, address actualFrom, address actualTo, uint256 actualTokenId, address actualOwnerDuring) =
            IRewardNFTIntegrationHarness(address(diamond)).callbackRecord();

        assertEq(actualCount, count);
        assertEq(actualFrom, from);
        assertEq(actualTo, to);
        assertEq(actualTokenId, tokenId);
        assertEq(actualOwnerDuring, ownerDuring);
    }

    function _deployCoreDiamond() private returns (CrottoDiamond deployed) {
        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](3);
        initialCut[0] = IDiamondCut.FacetCut({
            facetAddress: address(cutFacet), action: IDiamondCut.FacetCutAction.Add, functionSelectors: _cutSelectors()
        });
        initialCut[1] = IDiamondCut.FacetCut({
            facetAddress: address(loupeFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _loupeSelectors()
        });
        initialCut[2] = IDiamondCut.FacetCut({
            facetAddress: address(ownershipFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _ownershipSelectors()
        });
        deployed = new CrottoDiamond(
            owner, initialCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function _installIntegrationFacet() private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(integrationFacet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: _integrationSelectors()
        });
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
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

    function _integrationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IRewardNFTIntegrationHarness.configureRewardNFT.selector;
        selectors[1] = IRewardNFTIntegrationHarness.mintRewardNFT.selector;
        selectors[2] = IRewardNFTIntegrationHarness.onRewardNFTTransfer.selector;
        selectors[3] = IRewardNFTIntegrationHarness.scopedTransfer.selector;
        selectors[4] = IRewardNFTIntegrationHarness.callbackRecord.selector;
    }
}
