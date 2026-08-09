// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC173} from "../../interfaces/diamond/IERC173.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Ownership surface that will be transferred to the Crotto timelock.
contract OwnershipFacet is IERC173 {
    function owner() external view returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    function transferOwnership(address newOwner) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(newOwner);
    }
}
