// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";

contract RewardAccountingSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/RewardAccountingFacet.sol/RewardAccountingFacet.json";

    function test_ArtifactExposesOnlyApprovedRewardAccountingSelectors() public view {
        bytes4[] memory selectors = _artifactSelectors(FACET_ARTIFACT);
        assertEq(selectors.length, 6);
        _assertContains(selectors, RewardAccountingFacet.routeHookRevenue.selector);
        _assertContains(selectors, RewardAccountingFacet.totalActiveWeight.selector);
        _assertContains(selectors, RewardAccountingFacet.wethRewardBook.selector);
        _assertContains(selectors, RewardAccountingFacet.tokenRewardBook.selector);
        _assertContains(selectors, RewardAccountingFacet.nftRewardPosition.selector);
        _assertContains(selectors, RewardAccountingFacet.pendingNFTRewards.selector);
    }

    function _artifactSelectors(string memory artifactPath) private view returns (bytes4[] memory selectors) {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(artifactPath), ".methodIdentifiers");
        selectors = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _assertContains(bytes4[] memory selectors, bytes4 expected) private pure {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
