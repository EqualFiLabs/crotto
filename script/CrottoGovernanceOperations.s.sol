// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {CrottoTimelock} from "../src/governance/CrottoTimelock.sol";
import {ICrottoGovernance} from "../src/interfaces/ICrottoGovernance.sol";
import {ICrottoSwapFeeHook} from "../src/interfaces/ICrottoSwapFeeHook.sol";
import {ICrottoView} from "../src/interfaces/ICrottoView.sol";
import {HookConfiguration} from "../src/types/CrottoTypes.sol";
import {CrottoDeploymentConfig, CrottoDeploymentConfiguration} from "./CrottoDeploymentConfig.sol";
import {CrottoScriptBase} from "./CrottoScriptBase.sol";

/// @notice Shared scheduling mechanics for the explicitly supported Crotto governance operations.
abstract contract CrottoGovernanceOperation is CrottoScriptBase {
    error DiamondNotOwnedByTimelock(address owner, address timelock);
    error GovernanceOperationIncomplete(bytes32 operationId);
    error UnexpectedGovernanceResult(bytes32 field);

    function _configuration() internal returns (CrottoDeploymentConfiguration memory configuration) {
        CrottoDeploymentConfig reader =
            CrottoDeploymentConfig(_deployArtifact("CrottoDeploymentConfig.sol:CrottoDeploymentConfig", bytes("")));
        configuration = reader.loadConfiguration(vm.envString("CROTTO_DEPLOYMENT_CONFIG"));
        reader.validateEconomics(configuration);
    }

    function _schedule(bytes memory payload) internal returns (bytes32 operationId) {
        address diamond = vm.envAddress("CROTTO_DIAMOND");
        CrottoTimelock timelock = CrottoTimelock(payable(vm.envAddress("CROTTO_TIMELOCK")));
        _requireTimelockOwnership(diamond, address(timelock));
        bytes32 salt = vm.envBytes32("OPERATION_SALT");
        uint256 delay = timelock.getMinDelay();

        vm.startBroadcast(vm.envAddress("PROPOSER"));
        timelock.schedule(diamond, 0, payload, bytes32(0), salt, delay);
        vm.stopBroadcast();
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);
        if (!timelock.isOperationPending(operationId)) revert GovernanceOperationIncomplete(operationId);
    }

    function _execute(bytes memory payload) internal returns (bytes32 operationId) {
        address diamond = vm.envAddress("CROTTO_DIAMOND");
        CrottoTimelock timelock = CrottoTimelock(payable(vm.envAddress("CROTTO_TIMELOCK")));
        _requireTimelockOwnership(diamond, address(timelock));
        bytes32 salt = vm.envBytes32("OPERATION_SALT");
        operationId = timelock.hashOperation(diamond, 0, payload, bytes32(0), salt);

        vm.startBroadcast(vm.envAddress("EXECUTOR"));
        timelock.execute(diamond, 0, payload, bytes32(0), salt);
        vm.stopBroadcast();
        if (!timelock.isOperationDone(operationId)) revert GovernanceOperationIncomplete(operationId);
    }

    function _requireTimelockOwnership(address diamond, address timelock) private view {
        (bool success, bytes memory returned) = diamond.staticcall(abi.encodeWithSignature("owner()"));
        address owner = success && returned.length == 32 ? abi.decode(returned, (address)) : address(0);
        if (owner != timelock) revert DiamondNotOwnedByTimelock(owner, timelock);
    }
}

contract ScheduleRoundConfiguration is CrottoGovernanceOperation {
    function run() external returns (bytes32) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        return _schedule(abi.encodeCall(ICrottoGovernance.setRoundConfiguration, (configuration.round)));
    }
}

contract ExecuteRoundConfiguration is CrottoGovernanceOperation {
    function run() external returns (bytes32 operationId) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        operationId = _execute(abi.encodeCall(ICrottoGovernance.setRoundConfiguration, (configuration.round)));
        if (
            keccak256(abi.encode(ICrottoView(vm.envAddress("CROTTO_DIAMOND")).currentRoundConfiguration()))
                != keccak256(abi.encode(configuration.round))
        ) revert UnexpectedGovernanceResult("roundConfiguration");
    }
}

contract ScheduleBuybackConfiguration is CrottoGovernanceOperation {
    function run() external returns (bytes32) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        return _schedule(abi.encodeCall(ICrottoGovernance.setBuybackConfiguration, (configuration.buyback)));
    }
}

contract ExecuteBuybackConfiguration is CrottoGovernanceOperation {
    function run() external returns (bytes32 operationId) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        operationId = _execute(abi.encodeCall(ICrottoGovernance.setBuybackConfiguration, (configuration.buyback)));
        if (
            keccak256(abi.encode(ICrottoGovernance(vm.envAddress("CROTTO_DIAMOND")).buybackConfiguration()))
                != keccak256(abi.encode(configuration.buyback))
        ) revert UnexpectedGovernanceResult("buybackConfiguration");
    }
}

contract ScheduleTreasuryReceiver is CrottoGovernanceOperation {
    function run() external returns (bytes32) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        return _schedule(abi.encodeCall(ICrottoGovernance.setTreasuryReceiver, (configuration.treasuryReceiver)));
    }
}

contract ExecuteTreasuryReceiver is CrottoGovernanceOperation {
    function run() external returns (bytes32 operationId) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        operationId = _execute(abi.encodeCall(ICrottoGovernance.setTreasuryReceiver, (configuration.treasuryReceiver)));
        if (ICrottoGovernance(vm.envAddress("CROTTO_DIAMOND")).treasuryReceiver() != configuration.treasuryReceiver) {
            revert UnexpectedGovernanceResult("treasuryReceiver");
        }
    }
}

contract ScheduleHookConfiguration is CrottoGovernanceOperation {
    function run() external returns (bytes32) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        return _schedule(abi.encodeCall(ICrottoGovernance.setHookConfiguration, (configuration.hook)));
    }
}

contract ExecuteHookConfiguration is CrottoGovernanceOperation {
    function run() external returns (bytes32 operationId) {
        CrottoDeploymentConfiguration memory configuration = _configuration();
        operationId = _execute(abi.encodeCall(ICrottoGovernance.setHookConfiguration, (configuration.hook)));
        address hook = vm.envAddress("CROTTO_CANONICAL_HOOK");
        HookConfiguration memory actual = ICrottoSwapFeeHook(hook).hookConfiguration();
        if (keccak256(abi.encode(actual)) != keccak256(abi.encode(configuration.hook))) {
            revert UnexpectedGovernanceResult("hookConfiguration");
        }
    }
}

contract SchedulePOLAddition is CrottoGovernanceOperation {
    function run() external returns (bytes32) {
        return _schedule(
            abi.encodeCall(
                ICrottoGovernance.addPOL,
                (vm.envAddress("POL_FUNDER"), vm.envUint("POL_TOKEN_AMOUNT"), vm.envUint("POL_WETH_AMOUNT"))
            )
        );
    }
}

contract ExecutePOLAddition is CrottoGovernanceOperation {
    function run() external returns (bytes32 operationId) {
        operationId = _execute(
            abi.encodeCall(
                ICrottoGovernance.addPOL,
                (vm.envAddress("POL_FUNDER"), vm.envUint("POL_TOKEN_AMOUNT"), vm.envUint("POL_WETH_AMOUNT"))
            )
        );
    }
}
