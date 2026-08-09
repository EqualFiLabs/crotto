// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Standard EIP-2535 interface for changing Diamond selector routing.
interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    event DiamondCut(FacetCut[] diamondCut, address init, bytes initCalldata);

    function diamondCut(FacetCut[] calldata diamondCut, address init, bytes calldata initCalldata) external;
}
