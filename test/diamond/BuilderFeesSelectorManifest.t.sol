// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {BuilderFeesFacet} from "../../src/diamond/facets/BuilderFeesFacet.sol";

contract BuilderFeesSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/BuilderFeesFacet.sol/BuilderFeesFacet.json";

    function test_ArtifactExposesOnlyApprovedBuilderFeeSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 9);
        _assertContains(signatures, bytes4(keccak256("MAX_BUILDER_FEE_BPS()")));
        _assertContains(signatures, BuilderFeesFacet.approveBuilder.selector);
        _assertContains(signatures, BuilderFeesFacet.revokeBuilder.selector);
        _assertContains(signatures, BuilderFeesFacet.claimBuilderFees.selector);
        _assertContains(signatures, BuilderFeesFacet.builderApproval.selector);
        _assertContains(signatures, BuilderFeesFacet.builderCredit.selector);
        _assertContains(signatures, BuilderFeesFacet.totalBuilderFeeLiability.selector);
        _assertContains(signatures, BuilderFeesFacet.settleBuilderFees.selector);
        _assertContains(signatures, BuilderFeesFacet.provisionalBuilderCredit.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
