// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";

contract MutableSelectorFacet {
    function alpha() external pure returns (uint256) {
        return 1;
    }

    function bravo() external pure returns (uint256) {
        return 2;
    }

    function charlie() external pure returns (uint256) {
        return 3;
    }

    function delta() external pure returns (uint256) {
        return 4;
    }

    function echo() external pure returns (uint256) {
        return 5;
    }

    function foxtrot() external pure returns (uint256) {
        return 6;
    }

    function golf() external pure returns (uint256) {
        return 7;
    }

    function hotel() external pure returns (uint256) {
        return 8;
    }
}

contract DiamondCutHandler {
    IDiamondCut private immutable DIAMOND_CUT;
    IDiamondLoupe private immutable LOUPE;
    address[] private candidateFacets;
    bytes4[] private mutableSelectors;

    constructor(address diamond, address[] memory facets_, bytes4[] memory selectors_) {
        DIAMOND_CUT = IDiamondCut(diamond);
        LOUPE = IDiamondLoupe(diamond);
        candidateFacets = facets_;
        mutableSelectors = selectors_;
    }

    function mutate(uint256 selectorSeed, uint256 facetSeed, uint256 actionSeed) external {
        bytes4 selector = mutableSelectors[selectorSeed % mutableSelectors.length];
        address targetFacet = candidateFacets[facetSeed % candidateFacets.length];
        address currentFacet = LOUPE.facetAddress(selector);
        uint256 action = actionSeed % 3;

        IDiamondCut.FacetCutAction cutAction;
        address cutFacetAddress;
        if (action == uint256(IDiamondCut.FacetCutAction.Add)) {
            if (currentFacet != address(0)) return;
            cutAction = IDiamondCut.FacetCutAction.Add;
            cutFacetAddress = targetFacet;
        } else if (action == uint256(IDiamondCut.FacetCutAction.Replace)) {
            if (currentFacet == address(0) || currentFacet == targetFacet) return;
            cutAction = IDiamondCut.FacetCutAction.Replace;
            cutFacetAddress = targetFacet;
        } else {
            if (currentFacet == address(0)) return;
            cutAction = IDiamondCut.FacetCutAction.Remove;
        }

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: cutFacetAddress, action: cutAction, functionSelectors: selectors});
        DIAMOND_CUT.diamondCut(cuts, address(0), "");
    }
}

contract DiamondCutInvariantTest is StdInvariant, Test {
    DiamondCutFacet private cutFacet;
    DiamondLoupeFacet private loupeFacet;
    OwnershipFacet private ownershipFacet;
    CrottoDiamondInit private initializer;
    CrottoDiamond private diamond;
    DiamondCutHandler private handler;

    address[] private candidateFacets;
    bytes4[] private mutableSelectors;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        initializer = new CrottoDiamondInit();

        diamond = _deployCoreDiamond();
        for (uint256 i; i < 4; ++i) {
            candidateFacets.push(address(new MutableSelectorFacet()));
        }
        mutableSelectors = _mutableSelectors();
        _addInitialMutableSelectors();

        handler = new DiamondCutHandler(address(diamond), candidateFacets, mutableSelectors);
        IERC173(address(diamond)).transferOwnership(address(handler));

        bytes4[] memory targetSelectors = new bytes4[](1);
        targetSelectors[0] = DiamondCutHandler.mutate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: targetSelectors}));
    }

    function invariant_LoupeRemainsBijectiveAcrossRandomCuts() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        IDiamondLoupe.Facet[] memory facets_ = loupe.facets();
        uint256 enumeratedSelectors;

        for (uint256 i; i < facets_.length; ++i) {
            assertNotEq(facets_[i].facetAddress, address(0));
            assertGt(facets_[i].facetAddress.code.length, 0);
            assertGt(facets_[i].functionSelectors.length, 0);

            for (uint256 j; j < facets_[i].functionSelectors.length; ++j) {
                bytes4 selector = facets_[i].functionSelectors[j];
                assertEq(loupe.facetAddress(selector), facets_[i].facetAddress);
                ++enumeratedSelectors;

                for (uint256 k = i; k < facets_.length; ++k) {
                    uint256 start = k == i ? j + 1 : 0;
                    for (uint256 m = start; m < facets_[k].functionSelectors.length; ++m) {
                        assertNotEq(selector, facets_[k].functionSelectors[m]);
                    }
                }
            }
        }

        uint256 installedMutableSelectors;
        for (uint256 i; i < mutableSelectors.length; ++i) {
            address facet = loupe.facetAddress(mutableSelectors[i]);
            if (facet == address(0)) continue;
            assertTrue(_isCandidateFacet(facet));
            ++installedMutableSelectors;
        }
        assertEq(enumeratedSelectors, 8 + installedMutableSelectors);
    }

    function invariant_CoreSelectorsAndOwnershipRemainStable() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(cutFacet));
        assertEq(loupe.facetAddress(IDiamondLoupe.facets.selector), address(loupeFacet));
        assertEq(loupe.facetAddress(IDiamondLoupe.facetFunctionSelectors.selector), address(loupeFacet));
        assertEq(loupe.facetAddress(IDiamondLoupe.facetAddresses.selector), address(loupeFacet));
        assertEq(loupe.facetAddress(IDiamondLoupe.facetAddress.selector), address(loupeFacet));
        assertEq(loupe.facetAddress(IERC165.supportsInterface.selector), address(loupeFacet));
        assertEq(loupe.facetAddress(IERC173.owner.selector), address(ownershipFacet));
        assertEq(loupe.facetAddress(IERC173.transferOwnership.selector), address(ownershipFacet));
        assertEq(IERC173(address(diamond)).owner(), address(handler));
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
            address(this), initialCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function _addInitialMutableSelectors() private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: candidateFacets[0],
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: mutableSelectors
        });
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function _isCandidateFacet(address facet) private view returns (bool) {
        for (uint256 i; i < candidateFacets.length; ++i) {
            if (candidateFacets[i] == facet) return true;
        }
        return false;
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

    function _mutableSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = MutableSelectorFacet.alpha.selector;
        selectors[1] = MutableSelectorFacet.bravo.selector;
        selectors[2] = MutableSelectorFacet.charlie.selector;
        selectors[3] = MutableSelectorFacet.delta.selector;
        selectors[4] = MutableSelectorFacet.echo.selector;
        selectors[5] = MutableSelectorFacet.foxtrot.selector;
        selectors[6] = MutableSelectorFacet.golf.selector;
        selectors[7] = MutableSelectorFacet.hotel.selector;
    }
}
