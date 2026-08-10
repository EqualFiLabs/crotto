// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {RewardClaimsFacet} from "../../src/diamond/facets/RewardClaimsFacet.sol";

contract RewardClaimsSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/RewardClaimsFacet.sol/RewardClaimsFacet.json";

    function test_ArtifactExposesOnlyApprovedClaimAndTransferSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 3);
        _assertContains(signatures, RewardClaimsFacet.claimNFTWethReward.selector);
        _assertContains(signatures, RewardClaimsFacet.claimNFTTokenReward.selector);
        _assertContains(signatures, RewardClaimsFacet.onRewardNFTTransfer.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
