// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {BuybackSettlementFacet} from "../../src/diamond/facets/BuybackSettlementFacet.sol";

contract BuybackSettlementSelectorManifestTest is Test {
    string private constant FACET_ARTIFACT = "out/BuybackSettlementFacet.sol/BuybackSettlementFacet.json";

    function test_ArtifactExposesOnlyApprovedBuybackSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 2);
        bytes4 first = bytes4(keccak256(bytes(signatures[0])));
        bytes4 second = bytes4(keccak256(bytes(signatures[1])));
        assertTrue(
            first == BuybackSettlementFacet.unlockCallback.selector
                || second == BuybackSettlementFacet.unlockCallback.selector
        );
        assertTrue(
            first == BuybackSettlementFacet.executePendingBuyback.selector
                || second == BuybackSettlementFacet.executePendingBuyback.selector
        );
    }
}
