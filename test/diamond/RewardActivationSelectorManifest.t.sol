// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {RewardActivationFacet} from "../../src/diamond/facets/RewardActivationFacet.sol";

contract RewardActivationSelectorManifestTest is Test {
    string private constant FACET_ARTIFACT = "out/RewardActivationFacet.sol/RewardActivationFacet.json";

    function test_ArtifactExposesOnlyActivationSelector() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 1);
        assertEq(bytes4(keccak256(bytes(signatures[0]))), RewardActivationFacet.activateNextTier.selector);
    }
}
