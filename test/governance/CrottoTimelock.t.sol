// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CrottoTimelock} from "../../src/governance/CrottoTimelock.sol";

contract TimelockTarget {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract CrottoTimelockTest is Test {
    address private proposer = makeAddr("proposer");
    address private stranger = makeAddr("stranger");

    CrottoTimelock private timelock;
    TimelockTarget private target;

    function setUp() public {
        vm.chainId(31_337);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        timelock = new CrottoTimelock(proposers, executors, address(0));
        target = new TimelockTarget();
    }

    function test_UsesDevelopmentDelayOnSupportedDevelopmentChains() public {
        assertEq(timelock.getMinDelay(), timelock.DEVELOPMENT_INITIAL_DELAY());

        vm.chainId(timelock.ROBINHOOD_TESTNET_CHAIN_ID());
        address[] memory empty = new address[](0);
        CrottoTimelock testnetTimelock = new CrottoTimelock(empty, empty, address(0));
        assertEq(testnetTimelock.getMinDelay(), timelock.DEVELOPMENT_INITIAL_DELAY());
    }

    function test_UsesProductionDelayOnOtherChains() public {
        vm.chainId(1);
        address[] memory empty = new address[](0);
        CrottoTimelock productionTimelock = new CrottoTimelock(empty, empty, address(0));
        assertEq(productionTimelock.getMinDelay(), timelock.PRODUCTION_INITIAL_DELAY());
    }

    function test_ProposerCanScheduleAndAnyoneCanExecuteAfterDelay() public {
        bytes memory payload = abi.encodeCall(TimelockTarget.setValue, (42));
        bytes32 salt = keccak256("open-execution");
        uint256 delay = timelock.getMinDelay();

        vm.prank(proposer);
        timelock.schedule(address(target), 0, payload, bytes32(0), salt, delay);

        vm.prank(stranger);
        vm.expectRevert();
        timelock.execute(address(target), 0, payload, bytes32(0), salt);

        vm.warp(block.timestamp + delay);
        vm.prank(stranger);
        timelock.execute(address(target), 0, payload, bytes32(0), salt);

        assertEq(target.value(), 42);
    }

    function test_ProposerCanCancelAndUnauthorizedAccountCannot() public {
        bytes memory payload = abi.encodeCall(TimelockTarget.setValue, (42));
        bytes32 salt = keccak256("cancel");
        bytes32 operationId = timelock.hashOperation(address(target), 0, payload, bytes32(0), salt);
        uint256 delay = timelock.getMinDelay();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();

        vm.prank(proposer);
        timelock.schedule(address(target), 0, payload, bytes32(0), salt, delay);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, cancellerRole)
        );
        timelock.cancel(operationId);

        vm.prank(proposer);
        timelock.cancel(operationId);
        assertFalse(timelock.isOperation(operationId));
    }

    function test_NoExternalAccountHasBootstrapAdmin() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), proposer));
    }

    function test_RoleChangesMustExecuteThroughTimelock() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes memory payload = abi.encodeWithSelector(IAccessControl.grantRole.selector, proposerRole, stranger);
        bytes32 salt = keccak256("self-governed-role-change");
        uint256 delay = timelock.getMinDelay();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, payload, bytes32(0), salt, delay);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole)
        );
        timelock.grantRole(proposerRole, stranger);

        vm.warp(block.timestamp + delay);
        vm.prank(stranger);
        timelock.execute(address(timelock), 0, payload, bytes32(0), salt);

        assertTrue(timelock.hasRole(proposerRole, stranger));
    }
}
