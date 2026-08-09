// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IDiamondCut} from "../interfaces/diamond/IDiamondCut.sol";
import {LibDiamond} from "./libraries/LibDiamond.sol";

/// @notice EIP-2535 core proxy and asset-custody boundary for Crotto.
contract CrottoDiamond {
    error FunctionNotFound(bytes4 selector);

    constructor(
        address initialOwner,
        IDiamondCut.FacetCut[] memory initialCut,
        address initializer,
        bytes memory initializerCalldata
    ) payable {
        LibDiamond.setContractOwner(initialOwner);
        LibDiamond.diamondCut(initialCut, initializer, initializerCalldata);
    }

    receive() external payable {}

    fallback() external payable {
        address facet = LibDiamond.facetAddress(msg.sig);
        if (facet == address(0)) revert FunctionNotFound(msg.sig);

        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
