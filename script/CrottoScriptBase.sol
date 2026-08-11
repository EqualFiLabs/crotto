// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Script} from "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/diamond/IDiamondLoupe.sol";

/// @notice Shared artifact deployment, selector extraction, and Diamond-manifest verification helpers.
abstract contract CrottoScriptBase is Script {
    error ArtifactDeploymentFailed(string artifact);
    error EmptyFacetSelectorSet(string facet);
    error UnexpectedFacetRouting(bytes4 selector, address expected, address actual);

    function facetSelectors(string memory facet) public view returns (bytes4[] memory selectors) {
        string memory artifactJson =
            vm.readFile(string.concat(vm.projectRoot(), "/out/", facet, ".sol/", facet, ".json"));
        string[] memory signatures = vm.parseJsonKeys(artifactJson, ".methodIdentifiers");
        uint256 length = signatures.length;
        if (length == 0) revert EmptyFacetSelectorSet(facet);
        selectors = new bytes4[](length);
        for (uint256 i; i < length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function manifestHash(address diamond) public view returns (bytes32) {
        return keccak256(abi.encode(IDiamondLoupe(diamond).facets()));
    }

    function _deployArtifact(string memory artifact, bytes memory constructorArguments)
        internal
        returns (address deployed)
    {
        bytes memory creationCode = abi.encodePacked(vm.getCode(artifact), constructorArguments);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        if (deployed == address(0)) revert ArtifactDeploymentFailed(artifact);
    }

    function _facetCut(address facet, string memory name, IDiamondCut.FacetCutAction action)
        internal
        view
        returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: facetSelectors(name)});
    }

    function _verifyFacetCut(address diamond, IDiamondCut.FacetCut memory cut) internal view {
        uint256 length = cut.functionSelectors.length;
        for (uint256 i; i < length; ++i) {
            bytes4 selector = cut.functionSelectors[i];
            address actual = IDiamondLoupe(diamond).facetAddress(selector);
            if (actual != cut.facetAddress) revert UnexpectedFacetRouting(selector, cut.facetAddress, actual);
        }
    }
}
