// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {OperationsFacet} from "../../src/diamond/facets/OperationsFacet.sol";

contract OperationsSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/OperationsFacet.sol/OperationsFacet.json";

    function test_ArtifactExposesOnlyApprovedOperationsSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 5);
        _assertContains(signatures, OperationsFacet.fundOperationsReserve.selector);
        _assertContains(signatures, OperationsFacet.claimCallerRewards.selector);
        _assertContains(signatures, OperationsFacet.callerCredit.selector);
        _assertContains(signatures, OperationsFacet.operationsReserve.selector);
        _assertContains(signatures, OperationsFacet.totalCallerCredits.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
