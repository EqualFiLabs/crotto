// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {OperationsFacet} from "../../src/diamond/facets/OperationsFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {LibOperationsAccounting} from "../../src/libraries/LibOperationsAccounting.sol";
import {LibTreasuryStorage} from "../../src/libraries/storage/LibTreasuryStorage.sol";
import {CallerAction} from "../../src/types/CrottoTypes.sol";

contract NativeCostSink {
    receive() external payable {}
}

contract RejectingNativeReceiver {
    receive() external payable {
        revert("native rejected");
    }
}

contract RefundingNativeReceiver {
    receive() external payable {
        (bool success,) = msg.sender.call{value: msg.value}("");
        require(success);
    }
}

contract LargeReturnDataNativeReceiver {
    receive() external payable {
        assembly ("memory-safe") {
            return(0, 0x100000)
        }
    }
}

contract OperationsLifecycleHarness is CrottoFacet {
    error HarnessActionOutOfBounds(uint256 action);
    error HarnessAttemptOutOfBounds(uint256 attempt);
    error RequestCostPaymentFailed(address receiver, uint256 amount);

    function processRequest(
        address caller,
        uint256 action,
        uint256 roundId,
        uint256 attempt,
        uint256 requestCost,
        uint256 callerReward,
        uint256 finalizationReserve,
        address costReceiver
    ) external nonReentrant {
        if (action > uint256(uint8(type(CallerAction).max))) {
            revert HarnessActionOutOfBounds(action);
        }
        if (attempt > type(uint32).max) revert HarnessAttemptOutOfBounds(attempt);
        LibOperationsAccounting.debitRequestAndCredit(
            caller, CallerAction(action), roundId, uint32(attempt), requestCost, callerReward, finalizationReserve
        );
        (bool success,) = payable(costReceiver).call{value: requestCost}("");
        if (!success) revert RequestCostPaymentFailed(costReceiver, requestCost);
        LibOperationsAccounting.enforceNativeSolvency();
    }

    function processFinalization(address caller, uint256 roundId, uint256 callerReward) external nonReentrant {
        LibOperationsAccounting.creditFinalization(caller, roundId, callerReward);
        LibOperationsAccounting.enforceNativeSolvency();
    }

    function wasCredited(bytes32 creditKey) external view returns (bool) {
        return LibTreasuryStorage.layout().callerRewardCredited[creditKey];
    }
}

contract OperationsReserveTest is Test {
    address private donor = makeAddr("donor");
    address private requestCaller = makeAddr("requestCaller");
    address private retryCaller = makeAddr("retryCaller");
    address private finalizer = makeAddr("finalizer");
    address private receiver = makeAddr("receiver");

    CrottoDiamond private diamond;
    OperationsFacet private operations;
    OperationsLifecycleHarness private lifecycle;
    NativeCostSink private sink;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        OperationsFacet operationsFacet = new OperationsFacet();
        OperationsLifecycleHarness lifecycleFacet = new OperationsLifecycleHarness();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _facetCut(address(cutFacet), _cutSelectors());
        cuts[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        cuts[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        cuts[3] = _facetCut(address(operationsFacet), _operationsSelectors());
        cuts[4] = _facetCut(address(lifecycleFacet), _lifecycleSelectors());

        diamond = new CrottoDiamond(
            address(this), cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
        operations = OperationsFacet(address(diamond));
        lifecycle = OperationsLifecycleHarness(address(diamond));
        sink = new NativeCostSink();
        vm.deal(donor, 100 ether);
    }

    function test_PermissionlessFundingCreatesOnlyOperationsReserve() public {
        vm.expectEmit(true, false, false, true, address(diamond));
        emit ICrotto.OperationsReserveFunded(donor, 5 ether);
        vm.prank(donor);
        operations.fundOperationsReserve{value: 5 ether}();

        assertEq(operations.operationsReserve(), 5 ether);
        assertEq(operations.totalCallerCredits(), 0);
        assertEq(operations.callerCredit(donor), 0);
        assertEq(address(diamond).balance, 5 ether);
    }

    function test_RequestAndRetriesDeductExactCostsWhilePreservingFinalizationFloor() public {
        _fund(10 ether);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ICrotto.CallerRewardCredited(requestCaller, CallerAction.RandomnessRequest, 1, 1 ether);
        lifecycle.processRequest(
            requestCaller, uint256(CallerAction.RandomnessRequest), 1, 1, 2 ether, 1 ether, 3 ether, address(sink)
        );
        assertEq(operations.operationsReserve(), 7 ether);
        assertEq(operations.callerCredit(requestCaller), 1 ether);
        assertEq(address(sink).balance, 2 ether);

        lifecycle.processRequest(
            retryCaller, uint256(CallerAction.RandomnessRetry), 1, 2, 1 ether, 1 ether, 3 ether, address(sink)
        );
        lifecycle.processRequest(
            retryCaller, uint256(CallerAction.RandomnessRetry), 1, 3, 1 ether, 1 ether, 3 ether, address(sink)
        );

        assertEq(operations.operationsReserve(), 3 ether);
        assertEq(operations.callerCredit(retryCaller), 2 ether);
        assertEq(operations.totalCallerCredits(), 3 ether);
        assertEq(address(sink).balance, 4 ether);
        assertEq(address(diamond).balance, operations.operationsReserve() + operations.totalCallerCredits());
    }

    function test_FinalizationCreditDeductsReserveOnce() public {
        _fund(5 ether);
        lifecycle.processFinalization(finalizer, 1, 3 ether);

        assertEq(operations.operationsReserve(), 2 ether);
        assertEq(operations.callerCredit(finalizer), 3 ether);
        assertEq(operations.totalCallerCredits(), 3 ether);
        assertEq(address(diamond).balance, 5 ether);

        bytes32 key = keccak256(abi.encode(CallerAction.Finalization, uint256(1)));
        assertTrue(lifecycle.wasCredited(key));
        _fund(1 ether);
        vm.expectRevert(abi.encodeWithSelector(LibOperationsAccounting.CallerRewardAlreadyCredited.selector, key));
        lifecycle.processFinalization(requestCaller, 1, 3 ether);
    }

    function test_CallerClaimsWithCeiAndLeavesReserveUntouched() public {
        _fund(10 ether);
        lifecycle.processRequest(
            requestCaller, uint256(CallerAction.RandomnessRequest), 1, 1, 2 ether, 1 ether, 3 ether, address(sink)
        );

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ICrotto.CallerRewardClaimed(requestCaller, receiver, 1 ether);
        vm.prank(requestCaller);
        uint256 claimed = operations.claimCallerRewards(receiver);

        assertEq(claimed, 1 ether);
        assertEq(receiver.balance, 1 ether);
        assertEq(operations.callerCredit(requestCaller), 0);
        assertEq(operations.totalCallerCredits(), 0);
        assertEq(operations.operationsReserve(), 7 ether);
        assertEq(address(diamond).balance, 7 ether);
    }

    function test_ClaimIgnoresReceiverReturnData() public {
        _fund(5 ether);
        lifecycle.processFinalization(finalizer, 1, 3 ether);
        LargeReturnDataNativeReceiver largeReturnData = new LargeReturnDataNativeReceiver();

        vm.prank(finalizer);
        uint256 claimed = operations.claimCallerRewards{gas: 3_000_000}(address(largeReturnData));

        assertEq(claimed, 3 ether);
        assertEq(address(largeReturnData).balance, 3 ether);
        assertEq(operations.callerCredit(finalizer), 0);
        assertEq(operations.totalCallerCredits(), 0);
        assertEq(operations.operationsReserve(), 2 ether);
    }

    function test_ReserveCarriesAcrossRoundsAndCreditsRemainIndependent() public {
        _fund(12 ether);
        lifecycle.processRequest(
            requestCaller, uint256(CallerAction.RandomnessRequest), 1, 1, 1 ether, 1 ether, 2 ether, address(sink)
        );
        lifecycle.processFinalization(finalizer, 1, 2 ether);
        lifecycle.processRequest(
            retryCaller, uint256(CallerAction.RandomnessRequest), 2, 1, 1 ether, 1 ether, 2 ether, address(sink)
        );

        assertEq(operations.operationsReserve(), 6 ether);
        assertEq(operations.callerCredit(requestCaller), 1 ether);
        assertEq(operations.callerCredit(finalizer), 2 ether);
        assertEq(operations.callerCredit(retryCaller), 1 ether);
        assertEq(operations.totalCallerCredits(), 4 ether);
        assertEq(address(diamond).balance, 10 ether);
    }

    function test_RevertWhen_RequestCannotPreserveFinalizationReserve() public {
        _fund(5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(LibOperationsAccounting.InsufficientOperationsReserve.selector, 5 ether, 6 ether)
        );
        lifecycle.processRequest(
            requestCaller, uint256(CallerAction.RandomnessRequest), 1, 1, 2 ether, 1 ether, 3 ether, address(sink)
        );

        assertEq(operations.operationsReserve(), 5 ether);
        assertEq(operations.totalCallerCredits(), 0);
        assertEq(address(sink).balance, 0);
    }

    function test_RevertWhen_SameRequestActionIsCreditedTwice() public {
        _fund(10 ether);
        lifecycle.processRequest(
            requestCaller, uint256(CallerAction.RandomnessRetry), 1, 2, 1 ether, 1 ether, 3 ether, address(sink)
        );
        bytes32 key = keccak256(abi.encode(CallerAction.RandomnessRetry, uint256(1), uint32(2)));
        assertTrue(lifecycle.wasCredited(key));

        vm.expectRevert(abi.encodeWithSelector(LibOperationsAccounting.CallerRewardAlreadyCredited.selector, key));
        lifecycle.processRequest(
            retryCaller, uint256(CallerAction.RandomnessRetry), 1, 2, 1 ether, 1 ether, 3 ether, address(sink)
        );

        assertEq(operations.callerCredit(requestCaller), 1 ether);
        assertEq(operations.callerCredit(retryCaller), 0);
        assertEq(operations.operationsReserve(), 8 ether);
        assertEq(address(sink).balance, 1 ether);
    }

    function test_RevertWhen_RequestCostPaymentFailsAndRestoresCreditKey() public {
        _fund(10 ether);
        RejectingNativeReceiver rejecting = new RejectingNativeReceiver();
        vm.expectRevert(
            abi.encodeWithSelector(
                OperationsLifecycleHarness.RequestCostPaymentFailed.selector, address(rejecting), 2 ether
            )
        );
        lifecycle.processRequest(
            requestCaller, uint256(CallerAction.RandomnessRequest), 1, 1, 2 ether, 1 ether, 3 ether, address(rejecting)
        );

        bytes32 key = keccak256(abi.encode(CallerAction.RandomnessRequest, uint256(1), uint32(1)));
        assertFalse(lifecycle.wasCredited(key));
        assertEq(operations.operationsReserve(), 10 ether);
        assertEq(operations.callerCredit(requestCaller), 0);
    }

    function test_RevertWhen_ClaimReceiverRejectsOrReturnsNativeEth() public {
        _fund(5 ether);
        lifecycle.processFinalization(finalizer, 1, 3 ether);

        RejectingNativeReceiver rejecting = new RejectingNativeReceiver();
        vm.prank(finalizer);
        vm.expectRevert(
            abi.encodeWithSelector(OperationsFacet.NativeTransferFailed.selector, address(rejecting), 3 ether)
        );
        operations.claimCallerRewards(address(rejecting));
        assertEq(operations.callerCredit(finalizer), 3 ether);

        RefundingNativeReceiver refunding = new RefundingNativeReceiver();
        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(OperationsFacet.UnexpectedNativeDebit.selector, 3 ether, 0));
        operations.claimCallerRewards(address(refunding));
        assertEq(operations.callerCredit(finalizer), 3 ether);
        assertEq(operations.totalCallerCredits(), 3 ether);
    }

    function test_RevertWhen_ContributionOrClaimReceiverIsInvalid() public {
        vm.prank(donor);
        vm.expectRevert(OperationsFacet.ZeroOperationsContribution.selector);
        operations.fundOperationsReserve();

        vm.prank(requestCaller);
        vm.expectRevert(abi.encodeWithSelector(OperationsFacet.InvalidCallerRewardReceiver.selector, address(0)));
        operations.claimCallerRewards(address(0));

        vm.prank(requestCaller);
        vm.expectRevert(abi.encodeWithSelector(OperationsFacet.InvalidCallerRewardReceiver.selector, address(diamond)));
        operations.claimCallerRewards(address(diamond));
    }

    function test_WethCustodyRemainsUnchangedByNativeAccounting() public {
        WETH9 weth = new WETH9();
        weth.deposit{value: 1 ether}();
        weth.transfer(address(diamond), 1 ether);
        _fund(5 ether);
        lifecycle.processFinalization(finalizer, 1, 3 ether);

        vm.prank(finalizer);
        operations.claimCallerRewards(receiver);

        assertEq(weth.balanceOf(address(diamond)), 1 ether);
        assertEq(operations.operationsReserve(), 2 ether);
        assertEq(address(diamond).balance, 2 ether);
    }

    function _fund(uint256 amount) private {
        vm.prank(donor);
        operations.fundOperationsReserve{value: amount}();
    }

    function _facetCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _cutSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = bytes4(keccak256("supportsInterface(bytes4)"));
    }

    function _ownershipSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
    }

    function _operationsSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = OperationsFacet.fundOperationsReserve.selector;
        selectors[1] = OperationsFacet.claimCallerRewards.selector;
        selectors[2] = OperationsFacet.callerCredit.selector;
        selectors[3] = OperationsFacet.operationsReserve.selector;
        selectors[4] = OperationsFacet.totalCallerCredits.selector;
    }

    function _lifecycleSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = OperationsLifecycleHarness.processRequest.selector;
        selectors[1] = OperationsLifecycleHarness.processFinalization.selector;
        selectors[2] = OperationsLifecycleHarness.wasCredited.selector;
    }
}
