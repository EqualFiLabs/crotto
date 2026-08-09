// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondCut} from "../../interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../interfaces/diamond/IERC173.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice One-time core interface registration executed in Diamond storage context.
contract CrottoDiamondInit {
    function initialize() external {
        LibDiamond.enforceSelectorExists(IDiamondCut.diamondCut.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facets.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facetFunctionSelectors.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facetAddresses.selector);
        LibDiamond.enforceSelectorExists(IDiamondLoupe.facetAddress.selector);
        LibDiamond.enforceSelectorExists(IERC165.supportsInterface.selector);
        LibDiamond.enforceSelectorExists(IERC173.owner.selector);
        LibDiamond.enforceSelectorExists(IERC173.transferOwnership.selector);

        LibDiamond.markCoreInterfacesInitialized();
    }
}
