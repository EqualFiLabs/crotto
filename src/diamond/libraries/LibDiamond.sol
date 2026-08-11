// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDiamondCut} from "../../interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../interfaces/diamond/IERC173.sol";
import {ICrottoGovernance} from "../../interfaces/ICrottoGovernance.sol";

/// @notice Selector routing, ownership, and interface state for the Crotto Diamond.
library LibDiamond {
    // keccak256(abi.encode(uint256(keccak256("crotto.storage.Diamond")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant DIAMOND_STORAGE_SLOT = 0xcad59909dc176a8b30b130c96173fde21ec83511a1f08142aa42621865550c00;

    error NotContractOwner(address caller, address owner);
    error ZeroAddress();
    error EmptyFacetCut();
    error FacetHasNoCode(address facet);
    error FacetCannotBeDiamond();
    error SelectorAlreadyExists(bytes4 selector);
    error SelectorDoesNotExist(bytes4 selector);
    error CannotReplaceSelectorWithSameFacet(bytes4 selector, address facet);
    error RemoveFacetAddressMustBeZero(address facet);
    error InitAddressIsZeroButCalldataIsNotEmpty();
    error InitCalldataIsEmpty(address init);
    error InitializationFailed(address init);
    error CoreInterfacesAlreadyInitialized();
    error RequiredSelectorMissing(bytes4 selector);

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 selector => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address facet => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(bytes4 interfaceId => bool) supportedInterfaces;
        address contractOwner;
        bool coreInterfacesInitialized;
    }

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 slot = DIAMOND_STORAGE_SLOT;
        assembly ("memory-safe") {
            ds.slot := slot
        }
    }

    function diamondStorageSlot() internal pure returns (bytes32) {
        return DIAMOND_STORAGE_SLOT;
    }

    function contractOwner() internal view returns (address) {
        return diamondStorage().contractOwner;
    }

    function setContractOwner(address newOwner) internal {
        if (newOwner == address(0)) revert ZeroAddress();

        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = newOwner;
        emit IERC173.OwnershipTransferred(previousOwner, newOwner);
    }

    function enforceIsContractOwner() internal view {
        address owner_ = contractOwner();
        if (msg.sender != owner_) revert NotContractOwner(msg.sender, owner_);
    }

    function facetAddress(bytes4 selector) internal view returns (address) {
        return diamondStorage().selectorToFacetAndPosition[selector].facetAddress;
    }

    function setSupportedInterface(bytes4 interfaceId, bool supported) internal {
        diamondStorage().supportedInterfaces[interfaceId] = supported;
    }

    function enforceSelectorExists(bytes4 selector) internal view {
        if (facetAddress(selector) == address(0)) revert RequiredSelectorMissing(selector);
    }

    function manifestHash() internal view returns (bytes32) {
        DiamondStorage storage ds = diamondStorage();
        uint256 length = ds.facetAddresses.length;
        IDiamondLoupe.Facet[] memory facets_ = new IDiamondLoupe.Facet[](length);
        for (uint256 i; i < length; ++i) {
            address facet = ds.facetAddresses[i];
            facets_[i] = IDiamondLoupe.Facet({
                facetAddress: facet, functionSelectors: ds.facetFunctionSelectors[facet].functionSelectors
            });
        }
        return keccak256(abi.encode(facets_));
    }

    function selectorSetHash() internal view returns (bytes32 hash, uint256 count) {
        DiamondStorage storage ds = diamondStorage();
        uint256 facetCount = ds.facetAddresses.length;
        for (uint256 i; i < facetCount; ++i) {
            count += ds.facetFunctionSelectors[ds.facetAddresses[i]].functionSelectors.length;
        }

        bytes4[] memory selectors = new bytes4[](count);
        uint256 cursor;
        for (uint256 i; i < facetCount; ++i) {
            bytes4[] storage facetSelectors = ds.facetFunctionSelectors[ds.facetAddresses[i]].functionSelectors;
            for (uint256 j; j < facetSelectors.length; ++j) {
                selectors[cursor++] = facetSelectors[j];
            }
        }
        _sortSelectors(selectors);
        hash = keccak256(abi.encode(selectors));
    }

    function markCoreInterfacesInitialized() internal {
        DiamondStorage storage ds = diamondStorage();
        if (ds.coreInterfacesInitialized) revert CoreInterfacesAlreadyInitialized();
        ds.coreInterfacesInitialized = true;
    }

    function diamondCut(IDiamondCut.FacetCut[] memory cuts, address init, bytes memory initCalldata) internal {
        for (uint256 i; i < cuts.length; ++i) {
            IDiamondCut.FacetCutAction action = cuts[i].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                _addFunctions(cuts[i].facetAddress, cuts[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                _replaceFunctions(cuts[i].facetAddress, cuts[i].functionSelectors);
            } else {
                _removeFunctions(cuts[i].facetAddress, cuts[i].functionSelectors);
            }
        }

        emit IDiamondCut.DiamondCut(cuts, init, initCalldata);
        _initializeDiamondCut(init, initCalldata);
        if (diamondStorage().coreInterfacesInitialized) syncCoreInterfaces();
    }

    function syncCoreInterfaces() internal {
        DiamondStorage storage ds = diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = _selectorInstalled(ds, IERC165.supportsInterface.selector);
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = _selectorInstalled(ds, IDiamondCut.diamondCut.selector);
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = _selectorInstalled(ds, IDiamondLoupe.facets.selector)
            && _selectorInstalled(ds, IDiamondLoupe.facetFunctionSelectors.selector)
            && _selectorInstalled(ds, IDiamondLoupe.facetAddresses.selector)
            && _selectorInstalled(ds, IDiamondLoupe.facetAddress.selector);
        ds.supportedInterfaces[type(IERC173).interfaceId] = _selectorInstalled(ds, IERC173.owner.selector)
            && _selectorInstalled(ds, IERC173.transferOwnership.selector);
        ds.supportedInterfaces[type(ICrottoGovernance).interfaceId] = _selectorInstalled(
            ds, ICrottoGovernance.setRoundConfiguration.selector
        ) && _selectorInstalled(ds, ICrottoGovernance.setActivationConfiguration.selector)
        && _selectorInstalled(ds, ICrottoGovernance.setHookConfiguration.selector)
        && _selectorInstalled(ds, ICrottoGovernance.setBuybackConfiguration.selector)
        && _selectorInstalled(ds, ICrottoGovernance.setTreasuryReceiver.selector)
        && _selectorInstalled(ds, ICrottoGovernance.setGuardian.selector)
        && _selectorInstalled(ds, ICrottoGovernance.pauseActions.selector)
        && _selectorInstalled(ds, ICrottoGovernance.unpauseActions.selector)
        && _selectorInstalled(ds, ICrottoGovernance.treasuryReceiver.selector)
        && _selectorInstalled(ds, ICrottoGovernance.guardian.selector)
        && _selectorInstalled(ds, ICrottoGovernance.pausedActions.selector)
        && _selectorInstalled(ds, ICrottoGovernance.buybackConfiguration.selector);
    }

    function _addFunctions(address facet, bytes4[] memory selectors) private {
        if (selectors.length == 0) revert EmptyFacetCut();
        if (facet == address(0)) revert ZeroAddress();

        DiamondStorage storage ds = diamondStorage();
        _enforceValidFacet(facet);
        _addFacetIfMissing(ds, facet);

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            if (ds.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert SelectorAlreadyExists(selector);
            }
            _addSelector(ds, facet, selector);
        }
    }

    function _replaceFunctions(address facet, bytes4[] memory selectors) private {
        if (selectors.length == 0) revert EmptyFacetCut();
        if (facet == address(0)) revert ZeroAddress();

        DiamondStorage storage ds = diamondStorage();
        _enforceValidFacet(facet);

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == address(0)) revert SelectorDoesNotExist(selector);
            if (oldFacet == facet) revert CannotReplaceSelectorWithSameFacet(selector, facet);

            _removeSelector(ds, oldFacet, selector);
            _addFacetIfMissing(ds, facet);
            _addSelector(ds, facet, selector);
        }
    }

    function _removeFunctions(address facet, bytes4[] memory selectors) private {
        if (selectors.length == 0) revert EmptyFacetCut();
        if (facet != address(0)) revert RemoveFacetAddressMustBeZero(facet);

        DiamondStorage storage ds = diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == address(0)) revert SelectorDoesNotExist(selector);
            _removeSelector(ds, oldFacet, selector);
        }
    }

    function _addFacetIfMissing(DiamondStorage storage ds, address facet) private {
        if (ds.facetFunctionSelectors[facet].functionSelectors.length != 0) return;

        ds.facetFunctionSelectors[facet].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(facet);
    }

    function _addSelector(DiamondStorage storage ds, address facet, bytes4 selector) private {
        uint256 selectorPosition = ds.facetFunctionSelectors[facet].functionSelectors.length;
        // A facet cannot practically contain 2^96 selectors, so this packed cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 packedSelectorPosition = uint96(selectorPosition);
        ds.selectorToFacetAndPosition[selector] =
            FacetAddressAndPosition({facetAddress: facet, functionSelectorPosition: packedSelectorPosition});
        ds.facetFunctionSelectors[facet].functionSelectors.push(selector);
    }

    function _removeSelector(DiamondStorage storage ds, address facet, bytes4 selector) private {
        uint256 selectorPosition = ds.selectorToFacetAndPosition[selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[facet].functionSelectors.length - 1;

        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[facet].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[facet].functionSelectors[selectorPosition] = lastSelector;
            // The source position was previously stored in the same packed uint96 field.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint96 packedSelectorPosition = uint96(selectorPosition);
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = packedSelectorPosition;
        }

        ds.facetFunctionSelectors[facet].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[selector];

        if (lastSelectorPosition != 0) return;

        uint256 facetPosition = ds.facetFunctionSelectors[facet].facetAddressPosition;
        uint256 lastFacetPosition = ds.facetAddresses.length - 1;
        if (facetPosition != lastFacetPosition) {
            address lastFacet = ds.facetAddresses[lastFacetPosition];
            ds.facetAddresses[facetPosition] = lastFacet;
            ds.facetFunctionSelectors[lastFacet].facetAddressPosition = facetPosition;
        }

        ds.facetAddresses.pop();
        delete ds.facetFunctionSelectors[facet].facetAddressPosition;
    }

    function _initializeDiamondCut(address init, bytes memory initCalldata) private {
        if (init == address(0)) {
            if (initCalldata.length != 0) revert InitAddressIsZeroButCalldataIsNotEmpty();
            return;
        }
        if (initCalldata.length == 0) revert InitCalldataIsEmpty(init);

        _enforceHasCode(init);
        (bool success, bytes memory returndata) = init.delegatecall(initCalldata);
        if (success) return;
        if (returndata.length == 0) revert InitializationFailed(init);

        assembly ("memory-safe") {
            revert(add(returndata, 0x20), mload(returndata))
        }
    }

    function _enforceHasCode(address account) private view {
        if (account.code.length == 0) revert FacetHasNoCode(account);
    }

    function _enforceValidFacet(address facet) private view {
        if (facet == address(this)) revert FacetCannotBeDiamond();
        _enforceHasCode(facet);
    }

    function _selectorInstalled(DiamondStorage storage ds, bytes4 selector) private view returns (bool) {
        return ds.selectorToFacetAndPosition[selector].facetAddress != address(0);
    }

    function _sortSelectors(bytes4[] memory selectors) private pure {
        uint256 length = selectors.length;
        for (uint256 i = 1; i < length; ++i) {
            bytes4 value = selectors[i];
            uint256 j = i;
            while (j != 0 && uint32(selectors[j - 1]) > uint32(value)) {
                selectors[j] = selectors[j - 1];
                --j;
            }
            selectors[j] = value;
        }
    }
}
