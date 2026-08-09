// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../../interfaces/diamond/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Timelock-owned selector mutation surface for the Crotto Diamond.
contract DiamondCutFacet is IDiamondCut {
    function diamondCut(FacetCut[] calldata cuts, address init, bytes calldata initCalldata) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(cuts, init, initCalldata);
    }
}
