// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../interfaces/diamond/IDiamondCut.sol";
import {IERC173} from "../../interfaces/diamond/IERC173.sol";
import {ICrottoFinalImmutability} from "../../interfaces/ICrottoFinalImmutability.sol";
import {LibCrottoReleaseManifest} from "../libraries/LibCrottoReleaseManifest.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Timelock-owned selector mutation surface for the Crotto Diamond.
contract DiamondCutFacet is IDiamondCut, ICrottoFinalImmutability {
    error UnexpectedPreFinalManifest(bytes32 expected, bytes32 actual);
    error UnexpectedFinalSelectorSet(
        bytes32 expectedHash, bytes32 actualHash, uint256 expectedCount, uint256 actualCount
    );
    error FinalSelectorStillInstalled(bytes4 selector);
    error DiamondOwnershipChanged(address expected, address actual);

    function diamondCut(FacetCut[] calldata cuts, address init, bytes calldata initCalldata) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(cuts, init, initCalldata);
    }

    function finalizeImmutability(bytes32 expectedPreFinalManifestHash) external {
        LibDiamond.enforceIsContractOwner();
        bytes32 actualPreFinalManifestHash = LibDiamond.manifestHash();
        if (actualPreFinalManifestHash != expectedPreFinalManifestHash) {
            revert UnexpectedPreFinalManifest(expectedPreFinalManifestHash, actualPreFinalManifestHash);
        }

        address ownerBefore = LibDiamond.contractOwner();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = IDiamondCut.diamondCut.selector;
        selectors[1] = IERC173.transferOwnership.selector;
        selectors[2] = ICrottoFinalImmutability.finalizeImmutability.selector;
        FacetCut[] memory cuts = new FacetCut[](1);
        cuts[0] = FacetCut({facetAddress: address(0), action: FacetCutAction.Remove, functionSelectors: selectors});
        LibDiamond.diamondCut(cuts, address(0), bytes(""));

        (bytes32 finalSelectorSetHash, uint256 finalSelectorCount) = LibDiamond.selectorSetHash();
        if (
            finalSelectorSetHash != LibCrottoReleaseManifest.FINAL_SELECTOR_SET_HASH
                || finalSelectorCount != LibCrottoReleaseManifest.FINAL_SELECTOR_COUNT
        ) {
            revert UnexpectedFinalSelectorSet(
                LibCrottoReleaseManifest.FINAL_SELECTOR_SET_HASH,
                finalSelectorSetHash,
                LibCrottoReleaseManifest.FINAL_SELECTOR_COUNT,
                finalSelectorCount
            );
        }
        _enforceRemoved(IDiamondCut.diamondCut.selector);
        _enforceRemoved(IERC173.transferOwnership.selector);
        _enforceRemoved(ICrottoFinalImmutability.finalizeImmutability.selector);
        address ownerAfter = LibDiamond.contractOwner();
        if (ownerAfter != ownerBefore) revert DiamondOwnershipChanged(ownerBefore, ownerAfter);

        emit FinalImmutabilityCompleted(actualPreFinalManifestHash, LibDiamond.manifestHash());
    }

    function _enforceRemoved(bytes4 selector) private view {
        if (LibDiamond.facetAddress(selector) != address(0)) revert FinalSelectorStillInstalled(selector);
    }
}
