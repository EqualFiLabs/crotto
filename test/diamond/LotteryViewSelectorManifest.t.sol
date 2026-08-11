// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";

contract LotteryViewSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/LotteryViewFacet.sol/LotteryViewFacet.json";

    function test_ArtifactExposesOnlyApprovedRoundViewSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 10);
        _assertContains(signatures, LotteryViewFacet.currentRoundId.selector);
        _assertContains(signatures, LotteryViewFacet.round.selector);
        _assertContains(signatures, LotteryViewFacet.remainingTickets.selector);
        _assertContains(signatures, LotteryViewFacet.ticketBatchCount.selector);
        _assertContains(signatures, LotteryViewFacet.ticketBatch.selector);
        _assertContains(signatures, LotteryViewFacet.playerTickets.selector);
        _assertContains(signatures, LotteryViewFacet.rewardTickets.selector);
        _assertContains(signatures, LotteryViewFacet.playerRewardClaimed.selector);
        _assertContains(signatures, LotteryViewFacet.playerRewardEntitlement.selector);
        _assertContains(signatures, LotteryViewFacet.requestRecord.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
