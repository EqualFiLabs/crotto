// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {CrottoTimelock} from "../src/governance/CrottoTimelock.sol";
import {ICrotto} from "../src/interfaces/ICrotto.sol";
import {ICrottoGovernance} from "../src/interfaces/ICrottoGovernance.sol";
import {ICrottoBuilderFees} from "../src/interfaces/ICrottoBuilderFees.sol";
import {IDiamondCut} from "../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../src/interfaces/diamond/IERC173.sol";
import {IPOLInitialization} from "../src/interfaces/IPOLInitialization.sol";
import {CrottoScriptBase} from "./CrottoScriptBase.sol";

/// @notice Shared irreversible-cut construction and explicit release preconditions.
abstract contract CrottoFinalImmutability is CrottoScriptBase {
    error FinalImmutabilityNotConfirmed();
    error UnexpectedPreFinalManifest(bytes32 expected, bytes32 actual);
    error FinalOperationIncomplete(bytes32 operationId);
    error FinalSelectorStillInstalled(bytes4 selector);
    error RequiredSelectorMissing(bytes4 selector);
    error DiamondOwnershipChanged(address expected, address actual);
    error SelectorReinstallationSucceeded();

    function _payload(address diamond) internal view returns (bytes memory payload) {
        _requireConfirmationAndManifest(diamond);
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IDiamondCut.diamondCut.selector;
        selectors[1] = IERC173.transferOwnership.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: selectors
        });
        payload = abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), bytes("")));
    }

    function _scheduleFinalCut(address diamond, CrottoTimelock timelock, bytes memory payload)
        internal
        returns (bytes32 operationId)
    {
        bytes32 salt = vm.envBytes32("OPERATION_SALT");
        vm.startBroadcast(vm.envAddress("PROPOSER"));
        timelock.schedule(diamond, 0, payload, bytes32(0), salt, timelock.getMinDelay());
        vm.stopBroadcast();
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        if (!timelock.isOperationPending(operationId)) revert FinalOperationIncomplete(operationId);
    }

    function _executeFinalCut(address diamond, CrottoTimelock timelock, bytes memory payload)
        internal
        returns (bytes32 operationId)
    {
        bytes32 salt = vm.envBytes32("OPERATION_SALT");
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        vm.startBroadcast(vm.envAddress("EXECUTOR"));
        timelock.execute(diamond, 0, payload, bytes32(0), salt);
        vm.stopBroadcast();
        if (!timelock.isOperationDone(operationId)) revert FinalOperationIncomplete(operationId);
        _verifyFinalState(diamond, address(timelock));
    }

    function _requireConfirmationAndManifest(address diamond) private view {
        if (!vm.envBool("CONFIRM_FINAL_IMMUTABILITY")) revert FinalImmutabilityNotConfirmed();
        bytes32 expected = vm.envBytes32("EXPECTED_PRE_FINAL_MANIFEST_HASH");
        bytes32 actual = manifestHash(diamond);
        if (actual != expected) revert UnexpectedPreFinalManifest(expected, actual);
    }

    function _verifyFinalState(address diamond, address timelock) private {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        if (loupe.facetAddress(IDiamondCut.diamondCut.selector) != address(0)) {
            revert FinalSelectorStillInstalled(IDiamondCut.diamondCut.selector);
        }
        if (loupe.facetAddress(IERC173.transferOwnership.selector) != address(0)) {
            revert FinalSelectorStillInstalled(IERC173.transferOwnership.selector);
        }
        _requireSelector(loupe, ICrotto.buyTickets.selector);
        _requireSelector(loupe, ICrotto.buyTicketsWithBuilder.selector);
        _requireSelector(loupe, ICrottoBuilderFees.claimBuilderFees.selector);
        _requireSelector(loupe, ICrotto.finalizeLottery.selector);
        _requireSelector(loupe, ICrottoGovernance.setRoundConfiguration.selector);
        _requireSelector(loupe, IPOLInitialization.initializePOL.selector);
        if (IERC173(diamond).owner() != timelock) revert DiamondOwnershipChanged(timelock, IERC173(diamond).owner());

        IDiamondCut.FacetCut[] memory emptyCuts = new IDiamondCut.FacetCut[](0);
        (bool reinstalled,) = diamond.call(abi.encodeCall(IDiamondCut.diamondCut, (emptyCuts, address(0), bytes(""))));
        if (reinstalled) revert SelectorReinstallationSucceeded();
    }

    function _requireSelector(IDiamondLoupe loupe, bytes4 selector) private view {
        if (loupe.facetAddress(selector) == address(0)) revert RequiredSelectorMissing(selector);
    }
}

contract ScheduleFinalImmutability is CrottoFinalImmutability {
    function run() external returns (bytes32) {
        address diamond = vm.envAddress("CROTTO_DIAMOND");
        CrottoTimelock timelock = CrottoTimelock(payable(vm.envAddress("CROTTO_TIMELOCK")));
        return _scheduleFinalCut(diamond, timelock, _payload(diamond));
    }
}

contract ExecuteFinalImmutability is CrottoFinalImmutability {
    function run() external returns (bytes32) {
        address diamond = vm.envAddress("CROTTO_DIAMOND");
        CrottoTimelock timelock = CrottoTimelock(payable(vm.envAddress("CROTTO_TIMELOCK")));
        return _executeFinalCut(diamond, timelock, _payload(diamond));
    }
}
