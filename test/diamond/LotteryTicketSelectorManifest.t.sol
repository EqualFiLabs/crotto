// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LotteryTicketFacet} from "../../src/diamond/facets/LotteryTicketFacet.sol";

contract LotteryTicketSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/LotteryTicketFacet.sol/LotteryTicketFacet.json";

    function test_ArtifactExposesOnlyApprovedTicketSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 4);
        _assertContains(signatures, LotteryTicketFacet.buyTickets.selector);
        _assertContains(signatures, LotteryTicketFacet.buyTicketsWithBuilder.selector);
        _assertContains(signatures, LotteryTicketFacet.ticketQuote.selector);
        _assertContains(signatures, LotteryTicketFacet.builderTicketQuote.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
