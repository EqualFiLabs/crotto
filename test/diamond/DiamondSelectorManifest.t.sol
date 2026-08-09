// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";

contract ReplacementProbeFacet {
    function probe() external pure returns (uint256) {
        return 1;
    }
}

contract DiamondSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant CUT_ARTIFACT = "out/DiamondCutFacet.sol/DiamondCutFacet.json";
    string private constant LOUPE_ARTIFACT = "out/DiamondLoupeFacet.sol/DiamondLoupeFacet.json";
    string private constant OWNERSHIP_ARTIFACT = "out/OwnershipFacet.sol/OwnershipFacet.json";

    address private owner = makeAddr("owner");

    DiamondCutFacet private cutFacet;
    DiamondLoupeFacet private loupeFacet;
    OwnershipFacet private ownershipFacet;
    CrottoDiamondInit private initializer;
    CrottoDiamond private diamond;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory initialCut = new IDiamondCut.FacetCut[](3);
        initialCut[0] = _facetCut(address(cutFacet), _artifactSelectors(CUT_ARTIFACT));
        initialCut[1] = _facetCut(address(loupeFacet), _artifactSelectors(LOUPE_ARTIFACT));
        initialCut[2] = _facetCut(address(ownershipFacet), _artifactSelectors(OWNERSHIP_ARTIFACT));
        diamond = new CrottoDiamond(
            owner, initialCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
    }

    function test_CompiledCoreFacetManifestMatchesExactRouting() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        address[] memory addresses = loupe.facetAddresses();
        assertEq(addresses.length, 3);
        assertEq(_totalSelectorCount(loupe.facets()), 8);

        _assertSelectorSet(loupe.facetFunctionSelectors(address(cutFacet)), _artifactSelectors(CUT_ARTIFACT));
        _assertSelectorSet(loupe.facetFunctionSelectors(address(loupeFacet)), _artifactSelectors(LOUPE_ARTIFACT));
        _assertSelectorSet(
            loupe.facetFunctionSelectors(address(ownershipFacet)), _artifactSelectors(OWNERSHIP_ARTIFACT)
        );
        _assertNoDuplicateSelectors(loupe.facets());
    }

    function test_CoreFacetArtifactsExposeOnlyApprovedSelectors() public view {
        bytes4[] memory cutSelectors = _artifactSelectors(CUT_ARTIFACT);
        bytes4[] memory loupeSelectors = _artifactSelectors(LOUPE_ARTIFACT);
        bytes4[] memory ownershipSelectors = _artifactSelectors(OWNERSHIP_ARTIFACT);

        assertEq(cutSelectors.length, 1);
        assertEq(cutSelectors[0], IDiamondCut.diamondCut.selector);

        assertEq(loupeSelectors.length, 5);
        _assertContains(loupeSelectors, IDiamondLoupe.facets.selector);
        _assertContains(loupeSelectors, IDiamondLoupe.facetFunctionSelectors.selector);
        _assertContains(loupeSelectors, IDiamondLoupe.facetAddresses.selector);
        _assertContains(loupeSelectors, IDiamondLoupe.facetAddress.selector);
        _assertContains(loupeSelectors, IERC165.supportsInterface.selector);

        assertEq(ownershipSelectors.length, 2);
        _assertContains(ownershipSelectors, IERC173.owner.selector);
        _assertContains(ownershipSelectors, IERC173.transferOwnership.selector);
    }

    function test_InterfaceSupportTracksInstalledSelectorSet() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC173.transferOwnership.selector;
        _cut(address(0), IDiamondCut.FacetCutAction.Remove, selectors, address(0), "");
        assertFalse(IERC165(address(diamond)).supportsInterface(type(IERC173).interfaceId));

        _cut(address(ownershipFacet), IDiamondCut.FacetCutAction.Add, selectors, address(0), "");
        assertTrue(IERC165(address(diamond)).supportsInterface(type(IERC173).interfaceId));
    }

    function test_ReplacementRegistersNewFacetExactlyOnce() public {
        ReplacementProbeFacet firstFacet = new ReplacementProbeFacet();
        ReplacementProbeFacet secondFacet = new ReplacementProbeFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ReplacementProbeFacet.probe.selector;

        _cut(address(firstFacet), IDiamondCut.FacetCutAction.Add, selectors, address(0), "");
        _cut(address(secondFacet), IDiamondCut.FacetCutAction.Replace, selectors, address(0), "");

        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        address[] memory addresses = loupe.facetAddresses();
        uint256 secondFacetOccurrences;
        for (uint256 i; i < addresses.length; ++i) {
            if (addresses[i] == address(secondFacet)) ++secondFacetOccurrences;
        }

        assertEq(secondFacetOccurrences, 1);
        assertEq(loupe.facetFunctionSelectors(address(firstFacet)).length, 0);
        assertEq(loupe.facetFunctionSelectors(address(secondFacet)).length, 1);
        assertEq(loupe.facetAddress(ReplacementProbeFacet.probe.selector), address(secondFacet));
    }

    function test_RevertWhen_CoreInitializerRunsTwice() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(LibDiamond.CoreInterfacesAlreadyInitialized.selector);
        vm.prank(owner);
        IDiamondCut(address(diamond))
            .diamondCut(cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ()));
    }

    function test_RevertWhen_AtomicBootstrapOmitsRequiredSelector() public {
        IDiamondCut.FacetCut[] memory incompleteCut = new IDiamondCut.FacetCut[](2);
        incompleteCut[0] = _facetCut(address(cutFacet), _artifactSelectors(CUT_ARTIFACT));
        incompleteCut[1] = _facetCut(address(loupeFacet), _artifactSelectors(LOUPE_ARTIFACT));

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.RequiredSelectorMissing.selector, IERC173.owner.selector));
        new CrottoDiamond(owner, incompleteCut, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ()));
    }

    function _cut(
        address facet,
        IDiamondCut.FacetCutAction action,
        bytes4[] memory selectors,
        address init,
        bytes memory initCalldata
    ) private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, init, initCalldata);
    }

    function _facetCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _artifactSelectors(string memory artifactPath) private view returns (bytes4[] memory selectors) {
        // Paths are fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(artifactPath), ".methodIdentifiers");
        selectors = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _assertSelectorSet(bytes4[] memory actual, bytes4[] memory expected) private pure {
        assertEq(actual.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            _assertContains(actual, expected[i]);
        }
    }

    function _assertContains(bytes4[] memory selectors, bytes4 expected) private pure {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == expected) return;
        }
        revert SelectorMissing(expected);
    }

    function _assertNoDuplicateSelectors(IDiamondLoupe.Facet[] memory facets_) private pure {
        for (uint256 i; i < facets_.length; ++i) {
            assertGt(facets_[i].functionSelectors.length, 0);
            for (uint256 j; j < facets_[i].functionSelectors.length; ++j) {
                bytes4 selector = facets_[i].functionSelectors[j];
                for (uint256 k = i; k < facets_.length; ++k) {
                    uint256 start = k == i ? j + 1 : 0;
                    for (uint256 m = start; m < facets_[k].functionSelectors.length; ++m) {
                        assertNotEq(selector, facets_[k].functionSelectors[m], "duplicate routed selector");
                    }
                }
            }
        }
    }

    function _totalSelectorCount(IDiamondLoupe.Facet[] memory facets_) private pure returns (uint256 count) {
        for (uint256 i; i < facets_.length; ++i) {
            count += facets_[i].functionSelectors.length;
        }
    }
}
