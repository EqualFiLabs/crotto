// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondLoupe} from "../../interfaces/diamond/IDiamondLoupe.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Selector and interface introspection for the Crotto Diamond.
contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    function facets() external view returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 length = ds.facetAddresses.length;
        facets_ = new Facet[](length);
        for (uint256 i; i < length; ++i) {
            address facet = ds.facetAddresses[i];
            facets_[i] =
                Facet({facetAddress: facet, functionSelectors: ds.facetFunctionSelectors[facet].functionSelectors});
        }
    }

    function facetFunctionSelectors(address facet) external view returns (bytes4[] memory selectors) {
        selectors = LibDiamond.diamondStorage().facetFunctionSelectors[facet].functionSelectors;
    }

    function facetAddresses() external view returns (address[] memory facetAddresses_) {
        facetAddresses_ = LibDiamond.diamondStorage().facetAddresses;
    }

    function facetAddress(bytes4 selector) external view returns (address facetAddress_) {
        facetAddress_ = LibDiamond.facetAddress(selector);
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return LibDiamond.diamondStorage().supportedInterfaces[interfaceId];
    }
}
