// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Standard EIP-2535 interface for enumerating Diamond selector routing.
interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    function facets() external view returns (Facet[] memory facets_);

    function facetFunctionSelectors(address facet) external view returns (bytes4[] memory selectors);

    function facetAddresses() external view returns (address[] memory facetAddresses_);

    function facetAddress(bytes4 selector) external view returns (address facetAddress_);
}
