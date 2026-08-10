// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {LotteryVRFFacet} from "../../src/diamond/facets/LotteryVRFFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {OperationsFacet} from "../../src/diamond/facets/OperationsFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {
    IgnoredFulfillmentReason,
    ImmutableConfiguration,
    RequestRecord,
    Round,
    RoundConfiguration,
    RoundStatus
} from "../../src/types/CrottoTypes.sol";

contract NativeVrfWrapperMock {
    uint256 public price = 0.2 ether;
    uint256 public nextRequestId = 100;
    address public latestConsumer;
    uint32 public latestCallbackGasLimit;
    uint16 public latestRequestConfirmations;
    uint32 public latestNumWords;
    bytes32 public latestExtraArgsHash;
    bool public refundPayment;

    function setPrice(uint256 value) external {
        price = value;
    }

    function setNextRequestId(uint256 value) external {
        nextRequestId = value;
    }

    function setRefundPayment(bool value) external {
        refundPayment = value;
    }

    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) {
        return price;
    }

    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId) {
        require(msg.value == price, "wrong price");
        latestConsumer = msg.sender;
        latestCallbackGasLimit = callbackGasLimit;
        latestRequestConfirmations = requestConfirmations;
        latestNumWords = numWords;
        latestExtraArgsHash = keccak256(extraArgs);
        requestId = nextRequestId++;
        if (refundPayment) {
            (bool success,) = msg.sender.call{value: msg.value}("");
            require(success, "refund failed");
        }
    }

    function fulfill(uint256 requestId, uint256[] calldata words) external {
        ICrotto(latestConsumer).rawFulfillRandomWords(requestId, words);
    }
}

contract LotteryRandomnessStateHarness {
    function initializeRandomnessState(address wrapper, RoundConfiguration calldata configuration) external {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        governance.immutableConfiguration.vrfWrapper = wrapper;
        governance.immutableConfiguration.vrfCallbackGasLimit = 250_000;
        governance.immutableConfiguration.vrfRequestConfirmations = 3;

        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        lottery.currentRoundId = 1;
        lottery.rounds[1].status = RoundStatus.Closed;
        lottery.rounds[1].config = configuration;
        lottery.rounds[1].ticketCount = configuration.ticketTarget;
    }

    function setStatus(uint256 status) external {
        require(status <= uint256(uint8(type(RoundStatus).max)), "status bounds");
        LibLotteryStorage.layout().rounds[1].status = RoundStatus(status);
    }

    function setMaxVrfCost(uint256 maximumCost) external {
        LibLotteryStorage.layout().rounds[1].config.maxVrfCost = maximumCost;
    }
}

contract LotteryRandomnessTest is Test {
    uint256 private constant REQUEST_COST = 0.2 ether;
    uint256 private constant REQUEST_REWARD = 0.1 ether;
    uint256 private constant FINALIZATION_REWARD = 0.3 ether;
    uint256 private constant RETRY_DELAY = 10 minutes;

    address private donor = makeAddr("donor");
    address private requester = makeAddr("requester");
    address private retryCaller = makeAddr("retryCaller");

    CrottoDiamond private diamond;
    LotteryVRFFacet private randomness;
    LotteryViewFacet private views;
    OperationsFacet private operations;
    LotteryRandomnessStateHarness private stateHarness;
    NativeVrfWrapperMock private wrapper;

    function setUp() public {
        wrapper = new NativeVrfWrapperMock();
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        LotteryVRFFacet randomnessFacet = new LotteryVRFFacet();
        LotteryViewFacet viewFacet = new LotteryViewFacet();
        OperationsFacet operationsFacet = new OperationsFacet();
        LotteryRandomnessStateHarness harnessFacet = new LotteryRandomnessStateHarness();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = _facetCut(address(cutFacet), _cutSelectors());
        cuts[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        cuts[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        cuts[3] = _facetCut(address(randomnessFacet), _randomnessSelectors());
        cuts[4] = _facetCut(address(viewFacet), _viewSelectors());
        cuts[5] = _facetCut(address(operationsFacet), _operationsSelectors());
        cuts[6] = _facetCut(address(harnessFacet), _harnessSelectors());

        diamond = new CrottoDiamond(
            address(this), cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
        randomness = LotteryVRFFacet(address(diamond));
        views = LotteryViewFacet(address(diamond));
        operations = OperationsFacet(address(diamond));
        stateHarness = LotteryRandomnessStateHarness(address(diamond));
        stateHarness.initializeRandomnessState(address(wrapper), _roundConfiguration());

        vm.deal(donor, 100 ether);
        vm.prank(donor);
        operations.fundOperationsReserve{value: 20 ether}();
    }

    function test_FirstRequestUsesNativeDirectFundingAndRecordsAttempt() public {
        vm.warp(1 days);
        vm.prank(requester);
        uint256 requestId = randomness.requestRandomness(1);

        Round memory storedRound = views.round(1);
        RequestRecord memory record = views.requestRecord(requestId);
        assertEq(requestId, 100);
        assertEq(uint8(storedRound.status), uint8(RoundStatus.VRFPending));
        assertEq(storedRound.latestRequestAt, block.timestamp);
        assertEq(storedRound.requestAttempts, 1);
        assertEq(record.roundId, 1);
        assertEq(record.attempt, 1);
        assertTrue(record.known);
        assertEq(wrapper.latestConsumer(), address(diamond));
        assertEq(wrapper.latestCallbackGasLimit(), 250_000);
        assertEq(wrapper.latestRequestConfirmations(), 3);
        assertEq(wrapper.latestNumWords(), 1);
        bytes memory expectedArgs = VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}));
        assertEq(wrapper.latestExtraArgsHash(), keccak256(expectedArgs));
        assertEq(operations.operationsReserve(), 20 ether - REQUEST_COST - REQUEST_REWARD);
        assertEq(operations.callerCredit(requester), REQUEST_REWARD);
        assertEq(address(wrapper).balance, REQUEST_COST);
    }

    function test_RetryRequiresDelayAndRecordsEveryAttempt() public {
        vm.warp(1 days);
        vm.prank(requester);
        uint256 firstRequestId = randomness.requestRandomness(1);

        vm.warp(block.timestamp + RETRY_DELAY - 1);
        vm.prank(retryCaller);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryVRFFacet.RandomnessRetryTooEarly.selector, 1, RETRY_DELAY - 1, RETRY_DELAY)
        );
        randomness.retryRandomness(1);

        vm.warp(block.timestamp + 1);
        vm.prank(retryCaller);
        uint256 retryRequestId = randomness.retryRandomness(1);

        assertEq(retryRequestId, firstRequestId + 1);
        assertEq(views.requestRecord(firstRequestId).attempt, 1);
        assertEq(views.requestRecord(retryRequestId).attempt, 2);
        assertEq(views.round(1).requestAttempts, 2);
        assertEq(operations.callerCredit(retryCaller), REQUEST_REWARD);
    }

    function test_FirstFulfillmentWinsAcrossOutstandingAttempts() public {
        (uint256 firstRequestId, uint256 retryRequestId) = _requestAndRetry();
        _fulfill(firstRequestId, 77);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.RandomReady));
        assertEq(views.round(1).acceptedRandomWord, 77);

        _fulfill(retryRequestId, 88);
        assertEq(views.round(1).acceptedRandomWord, 77);

        vm.prank(retryCaller);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryVRFFacet.InvalidRandomnessRequestStatus.selector, 1, RoundStatus.RandomReady)
        );
        randomness.retryRandomness(1);
    }

    function test_MalformedAndUnknownFulfillmentsAreIgnored() public {
        vm.warp(1 days);
        vm.prank(requester);
        uint256 requestId = randomness.requestRandomness(1);

        uint256[] memory emptyWords = new uint256[](0);
        wrapper.fulfill(requestId, emptyWords);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.VRFPending));

        uint256[] memory words = new uint256[](1);
        words[0] = 9;
        wrapper.fulfill(requestId + 999, words);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.VRFPending));

        wrapper.fulfill(requestId, words);
        assertEq(views.round(1).acceptedRandomWord, 9);
    }

    function test_RevertWhen_CallbackCallerIsNotWrapper() public {
        uint256[] memory words = new uint256[](1);
        words[0] = 5;
        vm.expectRevert(
            abi.encodeWithSelector(LotteryVRFFacet.UnauthorizedVrfWrapper.selector, address(this), address(wrapper))
        );
        randomness.rawFulfillRandomWords(100, words);
    }

    function test_RevertWhen_QuoteExceedsRoundMaximumWithoutDebitingReserve() public {
        wrapper.setPrice(0.6 ether);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(LotteryVRFFacet.VrfCostExceedsMaximum.selector, 0.6 ether, 0.5 ether));
        randomness.requestRandomness(1);

        assertEq(operations.operationsReserve(), 20 ether);
        assertEq(operations.callerCredit(requester), 0);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.Closed));
    }

    function test_RevertWhen_ReserveCannotPreserveFinalizationReward() public {
        stateHarness.setMaxVrfCost(30 ether);
        wrapper.setPrice(19.7 ether);
        vm.prank(requester);
        vm.expectRevert();
        randomness.requestRandomness(1);

        assertEq(operations.operationsReserve(), 20 ether);
        assertEq(operations.callerCredit(requester), 0);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.Closed));
        assertEq(address(wrapper).balance, 0);
    }

    function test_RevertWhen_WrapperDoesNotRetainExactPayment() public {
        wrapper.setRefundPayment(true);
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(LotteryVRFFacet.UnexpectedNativeRequestDebit.selector, REQUEST_COST, 0));
        randomness.requestRandomness(1);

        assertEq(operations.operationsReserve(), 20 ether);
        assertEq(operations.callerCredit(requester), 0);
        assertEq(address(wrapper).balance, 0);
    }

    function test_RevertWhen_RoundIsUnknownOrNotClosed() public {
        vm.expectRevert(abi.encodeWithSelector(LotteryVRFFacet.UnknownRound.selector, 0));
        randomness.requestRandomness(0);
        vm.expectRevert(abi.encodeWithSelector(LotteryVRFFacet.UnknownRound.selector, 2));
        randomness.requestRandomness(2);

        stateHarness.setStatus(uint256(RoundStatus.Open));
        vm.expectRevert(
            abi.encodeWithSelector(LotteryVRFFacet.InvalidRandomnessRequestStatus.selector, 1, RoundStatus.Open)
        );
        randomness.requestRandomness(1);
    }

    function testFuzz_AcceptedWordNeverChanges(bool fulfillOlderFirst, uint256 olderWord, uint256 newerWord) public {
        (uint256 olderRequestId, uint256 newerRequestId) = _requestAndRetry();
        uint256 firstId = fulfillOlderFirst ? olderRequestId : newerRequestId;
        uint256 secondId = fulfillOlderFirst ? newerRequestId : olderRequestId;
        uint256 firstWord = fulfillOlderFirst ? olderWord : newerWord;
        uint256 secondWord = fulfillOlderFirst ? newerWord : olderWord;

        _fulfill(firstId, firstWord);
        _fulfill(secondId, secondWord);

        assertEq(views.round(1).acceptedRandomWord, firstWord);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.RandomReady));
    }

    function _requestAndRetry() private returns (uint256 firstRequestId, uint256 retryRequestId) {
        vm.warp(1 days);
        vm.prank(requester);
        firstRequestId = randomness.requestRandomness(1);
        vm.warp(block.timestamp + RETRY_DELAY);
        vm.prank(retryCaller);
        retryRequestId = randomness.retryRandomness(1);
    }

    function _fulfill(uint256 requestId, uint256 word) private {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        wrapper.fulfill(requestId, words);
    }

    function _roundConfiguration() private pure returns (RoundConfiguration memory configuration) {
        configuration.ticketPrice = 1 ether;
        configuration.ticketOperationsFee = 0.01 ether;
        configuration.playerRewardRate = 10 ether;
        configuration.ticketTarget = 10;
        configuration.maxVrfCost = 0.5 ether;
        configuration.vrfRetryDelay = RETRY_DELAY;
        configuration.requestCallerReward = REQUEST_REWARD;
        configuration.finalizationCallerReward = FINALIZATION_REWARD;
        configuration.winnerShareBps = 5_000;
        configuration.nftShareBps = 3_000;
        configuration.treasuryShareBps = 1_000;
        configuration.buybackShareBps = 1_000;
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

    function _randomnessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = LotteryVRFFacet.requestRandomness.selector;
        selectors[1] = LotteryVRFFacet.retryRandomness.selector;
        selectors[2] = LotteryVRFFacet.rawFulfillRandomWords.selector;
    }

    function _viewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = LotteryViewFacet.currentRoundId.selector;
        selectors[1] = LotteryViewFacet.round.selector;
        selectors[2] = LotteryViewFacet.remainingTickets.selector;
        selectors[3] = LotteryViewFacet.ticketBatchCount.selector;
        selectors[4] = LotteryViewFacet.ticketBatch.selector;
        selectors[5] = LotteryViewFacet.playerTickets.selector;
        selectors[6] = LotteryViewFacet.playerRewardClaimed.selector;
        selectors[7] = LotteryViewFacet.playerRewardEntitlement.selector;
        selectors[8] = LotteryViewFacet.requestRecord.selector;
    }

    function _operationsSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = OperationsFacet.fundOperationsReserve.selector;
        selectors[1] = OperationsFacet.claimCallerRewards.selector;
        selectors[2] = OperationsFacet.callerCredit.selector;
        selectors[3] = OperationsFacet.operationsReserve.selector;
        selectors[4] = OperationsFacet.totalCallerCredits.selector;
    }

    function _harnessSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = LotteryRandomnessStateHarness.initializeRandomnessState.selector;
        selectors[1] = LotteryRandomnessStateHarness.setStatus.selector;
        selectors[2] = LotteryRandomnessStateHarness.setMaxVrfCost.selector;
    }
}
