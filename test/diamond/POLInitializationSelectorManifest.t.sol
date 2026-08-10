// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {POLInitializationFacet} from "../../src/diamond/facets/POLInitializationFacet.sol";

contract POLInitializationSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/POLInitializationFacet.sol/POLInitializationFacet.json";

    function test_ArtifactExposesOnlyApprovedPOLInitializationSelectors() public view {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 10);
        _assertContains(signatures, POLInitializationFacet.initializePOL.selector);
        _assertContains(signatures, POLInitializationFacet.canInitializePOL.selector);
        _assertContains(signatures, POLInitializationFacet.polInitialized.selector);
        _assertContains(signatures, POLInitializationFacet.polInitializationAuthorized.selector);
        _assertContains(signatures, POLInitializationFacet.bootstrapPolWeth.selector);
        _assertContains(signatures, POLInitializationFacet.requiredBootstrapWeth.selector);
        _assertContains(signatures, POLInitializationFacet.bootstrapTokenMintAmount.selector);
        _assertContains(signatures, POLInitializationFacet.initialTokenPerWethWad.selector);
        _assertContains(signatures, POLInitializationFacet.canonicalPoolId.selector);
        _assertContains(signatures, POLInitializationFacet.polAccounting.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
