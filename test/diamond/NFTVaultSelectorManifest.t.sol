// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {NFTVaultFacet} from "../../src/diamond/facets/NFTVaultFacet.sol";

contract NFTVaultSelectorManifestTest is Test {
    error SelectorMissing(bytes4 selector);

    string private constant FACET_ARTIFACT = "out/NFTVaultFacet.sol/NFTVaultFacet.json";

    function test_ArtifactExposesOnlyApprovedVaultSelectors() public view {
        // Path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(FACET_ARTIFACT), ".methodIdentifiers");
        assertEq(signatures.length, 9);
        _assertContains(signatures, NFTVaultFacet.buyNewRewardNFT.selector);
        _assertContains(signatures, NFTVaultFacet.buyInventoryRewardNFT.selector);
        _assertContains(signatures, NFTVaultFacet.redeemRewardNFT.selector);
        _assertContains(signatures, NFTVaultFacet.vaultPrice.selector);
        _assertContains(signatures, NFTVaultFacet.vaultInventory.selector);
        _assertContains(signatures, NFTVaultFacet.circulatingNFTs.selector);
        _assertContains(signatures, NFTVaultFacet.requiredVaultBacking.selector);
        _assertContains(signatures, NFTVaultFacet.isVaultInventory.selector);
        _assertContains(signatures, NFTVaultFacet.vaultAccounting.selector);
    }

    function _assertContains(string[] memory signatures, bytes4 expected) private pure {
        for (uint256 i; i < signatures.length; ++i) {
            if (bytes4(keccak256(bytes(signatures[i]))) == expected) return;
        }
        revert SelectorMissing(expected);
    }
}
