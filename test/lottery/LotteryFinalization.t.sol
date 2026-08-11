// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {BuilderFeesFacet} from "../../src/diamond/facets/BuilderFeesFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {LotteryFinalizationFacet} from "../../src/diamond/facets/LotteryFinalizationFacet.sol";
import {LotteryTicketFacet} from "../../src/diamond/facets/LotteryTicketFacet.sol";
import {LotteryVRFFacet} from "../../src/diamond/facets/LotteryVRFFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {OperationsFacet} from "../../src/diamond/facets/OperationsFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {LibLottery} from "../../src/libraries/LibLottery.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {ImmutableConfiguration, Round, RoundConfiguration, RoundStatus} from "../../src/types/CrottoTypes.sol";
import {NativeVrfWrapperMock} from "./LotteryRandomness.t.sol";

contract PlayerRewardTokenMock is ERC20 {
    address public minter;

    constructor() ERC20("Player Reward", "PLAY") {}

    function setMinter(address account) external {
        require(minter == address(0), "minter set");
        minter = account;
    }

    function mintPlayerReward(address receiver, uint256 amount) external {
        require(msg.sender == minter, "not minter");
        _mint(receiver, amount);
    }
}

contract ShortMintPlayerRewardToken is ERC20 {
    constructor() ERC20("Short Reward", "SHORT") {}

    function mintPlayerReward(address receiver, uint256 amount) external {
        _mint(receiver, amount - 1);
    }
}

contract RejectingPrizeToken is ERC20 {
    constructor() ERC20("Rejecting Prize", "REJECT") {}

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("prize rejected");
    }
}

contract LotteryFinalizationStateHarness {
    function initializeLotteryState(
        address token,
        address weth,
        address wrapper,
        address treasuryReceiver,
        RoundConfiguration calldata configuration
    ) external {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        governance.immutableConfiguration.activationToken = token;
        governance.immutableConfiguration.weth = weth;
        governance.immutableConfiguration.vrfWrapper = wrapper;
        governance.immutableConfiguration.vrfCallbackGasLimit = 250_000;
        governance.immutableConfiguration.vrfRequestConfirmations = 3;
        governance.roundConfiguration = configuration;
        governance.treasuryReceiver = treasuryReceiver;
        LibLottery.initializeFirstRound(configuration);
    }

    function setNextRoundConfiguration(RoundConfiguration calldata configuration) external {
        LibGovernanceStorage.layout().roundConfiguration = configuration;
    }

    function setToken(address token) external {
        LibGovernanceStorage.layout().immutableConfiguration.activationToken = token;
    }

    function setWeth(address weth) external {
        LibGovernanceStorage.layout().immutableConfiguration.weth = weth;
    }

    function aggregateLiabilities() external view returns (uint256 winnerWeth, uint256 playerToken) {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        return (lottery.totalWinnerPoolWethLiability, lottery.totalPlayerTokenLiability);
    }
}

contract LotteryFinalizationTest is Test {
    uint256 private constant TICKET_PRICE = 1 ether;
    uint256 private constant OPERATIONS_FEE = 0.2 ether;
    uint256 private constant PLAYER_REWARD_RATE = 10 ether;

    address private playerA = makeAddr("playerA");
    address private playerB = makeAddr("playerB");
    address private outsider = makeAddr("outsider");
    address private requester = makeAddr("requester");
    address private finalizer = makeAddr("finalizer");
    address private treasury = makeAddr("treasury");
    address private receiver = makeAddr("receiver");

    CrottoDiamond private diamond;
    LotteryTicketFacet private ticketing;
    LotteryVRFFacet private randomness;
    LotteryFinalizationFacet private finalization;
    LotteryViewFacet private views;
    OperationsFacet private operations;
    BuilderFeesFacet private builderFees;
    LotteryFinalizationStateHarness private stateHarness;
    NativeVrfWrapperMock private wrapper;
    PlayerRewardTokenMock private token;
    WETH9 private weth;

    function setUp() public {
        wrapper = new NativeVrfWrapperMock();
        token = new PlayerRewardTokenMock();
        weth = new WETH9();

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        LotteryTicketFacet ticketFacet = new LotteryTicketFacet();
        LotteryVRFFacet vrfFacet = new LotteryVRFFacet();
        LotteryFinalizationFacet finalizationFacet = new LotteryFinalizationFacet();
        LotteryViewFacet viewFacet = new LotteryViewFacet();
        OperationsFacet operationsFacet = new OperationsFacet();
        BuilderFeesFacet builderFeesFacet = new BuilderFeesFacet();
        LotteryFinalizationStateHarness harnessFacet = new LotteryFinalizationStateHarness();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](10);
        cuts[0] = _facetCut(address(cutFacet), _cutSelectors());
        cuts[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        cuts[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        cuts[3] = _facetCut(address(ticketFacet), _ticketSelectors());
        cuts[4] = _facetCut(address(vrfFacet), _vrfSelectors());
        cuts[5] = _facetCut(address(finalizationFacet), _finalizationSelectors());
        cuts[6] = _facetCut(address(viewFacet), _viewSelectors());
        cuts[7] = _facetCut(address(operationsFacet), _operationsSelectors());
        cuts[8] = _facetCut(address(harnessFacet), _harnessSelectors());
        cuts[9] = _facetCut(address(builderFeesFacet), _builderSelectors());

        diamond = new CrottoDiamond(
            address(this), cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initialize, ())
        );
        token.setMinter(address(diamond));
        ticketing = LotteryTicketFacet(address(diamond));
        randomness = LotteryVRFFacet(address(diamond));
        finalization = LotteryFinalizationFacet(address(diamond));
        views = LotteryViewFacet(address(diamond));
        operations = OperationsFacet(address(diamond));
        builderFees = BuilderFeesFacet(address(diamond));
        stateHarness = LotteryFinalizationStateHarness(address(diamond));
        stateHarness.initializeLotteryState(
            address(token), address(weth), address(wrapper), treasury, _configuration(5)
        );

        vm.deal(playerA, 100 ether);
        vm.deal(playerB, 100 ether);
    }

    function test_EndToEndFinalizationClaimsAndRollover() public {
        _sellOut();
        _acceptRandomness(1);
        stateHarness.setNextRoundConfiguration(_configuration(7));

        vm.prank(finalizer);
        finalization.finalizeLottery(1);

        Round memory finalizedRound = views.round(1);
        Round memory nextRound = views.round(2);
        assertEq(uint8(finalizedRound.status), uint8(RoundStatus.Finalized));
        assertEq(finalizedRound.winningTicket, 1);
        assertEq(finalizedRound.winner, playerA);
        assertEq(finalizedRound.winnerPoolWeth, 2.5 ether);
        assertEq(finalizedRound.totalPlayerRewardLiability, 50 ether);
        assertEq(finalizedRound.unclaimedPlayerRewardLiability, 50 ether);
        assertEq(views.currentRoundId(), 2);
        assertEq(uint8(nextRound.status), uint8(RoundStatus.Open));
        assertEq(nextRound.config.ticketTarget, 7);
        assertEq(operations.callerCredit(finalizer), 0.3 ether);
        (uint256 winnerLiability, uint256 playerLiability) = stateHarness.aggregateLiabilities();
        assertEq(winnerLiability, 2.5 ether);
        assertEq(playerLiability, 50 ether);

        vm.prank(playerA);
        assertEq(finalization.claimWinnings(1, receiver), 2.5 ether);
        assertEq(weth.balanceOf(receiver), 2.5 ether);

        vm.prank(playerA);
        assertEq(finalization.claimPlayerRewards(1, playerA), 20 ether);
        vm.prank(playerB);
        assertEq(finalization.claimPlayerRewards(1, playerB), 30 ether);
        assertEq(token.balanceOf(playerA), 20 ether);
        assertEq(token.balanceOf(playerB), 30 ether);
        assertEq(token.totalSupply(), 50 ether);
        assertEq(views.round(1).unclaimedPlayerRewardLiability, 0);
        (winnerLiability, playerLiability) = stateHarness.aggregateLiabilities();
        assertEq(winnerLiability, 0);
        assertEq(playerLiability, 0);
        assertEq(views.round(2).ticketCount, 0);
    }

    function test_OperationalSpendingReopensTicketFeeHeadroomAfterRollover() public {
        _sellOut();
        _acceptRandomness(1);
        stateHarness.setNextRoundConfiguration(_configuration(7));
        finalization.finalizeLottery(1);

        assertEq(operations.operationsReserve(), 0.4 ether);
        vm.prank(playerA);
        ticketing.buyTickets{value: TICKET_PRICE + OPERATIONS_FEE}(1);

        assertEq(operations.operationsReserve(), 0.6 ether);
        assertEq(address(diamond).balance, 1 ether);
    }

    function test_LowerNextRoundCapPreservesCarriedReserveAndRoutesFullFeeToTreasury() public {
        _sellOut();
        _acceptRandomness(1);
        RoundConfiguration memory nextConfiguration = _configuration(7);
        nextConfiguration.maxVrfCost = 0.1 ether;
        nextConfiguration.requestCallerReward = 0.1 ether;
        nextConfiguration.finalizationCallerReward = 0.1 ether;
        nextConfiguration.operationsReserveCap = 0.3 ether;
        stateHarness.setNextRoundConfiguration(nextConfiguration);
        finalization.finalizeLottery(1);

        assertEq(operations.operationsReserve(), 0.4 ether);
        uint256 treasuryBefore = weth.balanceOf(treasury);
        vm.prank(playerA);
        ticketing.buyTickets{value: TICKET_PRICE + OPERATIONS_FEE}(1);

        assertEq(operations.operationsReserve(), 0.4 ether);
        assertEq(address(diamond).balance, 0.8 ether);
        assertEq(weth.balanceOf(treasury) - treasuryBefore, 0.2 ether);
    }

    function test_ClosedRoundExpiresAfterTimeoutAndRefundsTicketPrice() public {
        _sellOut();
        (uint256 unavailableWeth, uint256 unavailableBuilderFee, bool unavailableClaimed) =
            views.expiredRoundRefund(1, playerA);
        assertEq(unavailableWeth, 0);
        assertEq(unavailableBuilderFee, 0);
        assertFalse(unavailableClaimed);
        uint256 firstExpirableBlock = block.number + views.round(1).config.vrfTimeoutBlocks + 1;
        vm.roll(firstExpirableBlock - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LotteryFinalizationFacet.RoundTimeoutNotReached.selector, 1, block.number, firstExpirableBlock
            )
        );
        finalization.expireLottery(1);

        vm.roll(firstExpirableBlock);
        vm.prank(finalizer);
        finalization.expireLottery(1);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.Expired));
        assertEq(views.currentRoundId(), 2);
        assertEq(operations.callerCredit(finalizer), 0.3 ether);
        (uint256 claimableWeth, uint256 claimableBuilderFee, bool claimed) = views.expiredRoundRefund(1, playerA);
        assertEq(claimableWeth, 2 ether);
        assertEq(claimableBuilderFee, 0);
        assertFalse(claimed);

        vm.prank(playerA);
        (uint256 playerAWeth,) = finalization.claimExpiredRoundRefund(1, playerA, address(0));
        (claimableWeth, claimableBuilderFee, claimed) = views.expiredRoundRefund(1, playerA);
        assertEq(claimableWeth, 0);
        assertEq(claimableBuilderFee, 0);
        assertTrue(claimed);
        vm.prank(playerB);
        (uint256 playerBWeth,) = finalization.claimExpiredRoundRefund(1, playerB, address(0));
        assertEq(playerAWeth, 2 ether);
        assertEq(playerBWeth, 3 ether);
        assertEq(weth.balanceOf(playerA), 2 ether);
        assertEq(weth.balanceOf(playerB), 3 ether);

        vm.prank(playerA);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryFinalizationFacet.RoundNotFinalized.selector, 1, RoundStatus.Expired)
        );
        finalization.claimPlayerRewards(1, playerA);
    }

    function test_BuilderSurchargeRefundsBuyerInsteadOfMaturingBuilderCredit() public {
        address builder = makeAddr("builder");
        vm.prank(playerA);
        builderFees.approveBuilder(builder, 50, false);
        vm.prank(playerA);
        ticketing.buyTicketsWithBuilder{value: 2.405 ether}(2, builder, 25, false);
        vm.prank(playerB);
        ticketing.buyTickets{value: 3.6 ether}(3);

        vm.roll(block.number + views.round(1).config.vrfTimeoutBlocks + 1);
        finalization.expireLottery(1);
        vm.prank(playerA);
        (uint256 ticketRefund, uint256 builderRefund) = finalization.claimExpiredRoundRefund(1, playerA, playerA);
        assertEq(ticketRefund, 2 ether);
        assertEq(builderRefund, 0.005 ether);
        assertEq(builderFees.builderCredit(builder), 0);
        vm.prank(builder);
        vm.expectRevert(
            abi.encodeWithSelector(BuilderFeesFacet.BuilderRoundNotFinalized.selector, 1, RoundStatus.Expired)
        );
        builderFees.settleBuilderFees(1);
    }

    function testFuzz_BinarySearchResolvesEveryFrozenTicket(uint256 randomWord) public {
        _sellOut();
        _acceptRandomness(randomWord);
        finalization.finalizeLottery(1);

        uint256 winningTicket = randomWord % 5;
        address expectedWinner = winningTicket < 2 ? playerA : playerB;
        assertEq(views.round(1).winningTicket, winningTicket);
        assertEq(views.round(1).winner, expectedWinner);
    }

    function test_ClaimsCannotDuplicateAndRemainIndependent() public {
        _sellOut();
        _acceptRandomness(4);
        finalization.finalizeLottery(1);

        vm.prank(playerB);
        finalization.claimWinnings(1, playerB);
        vm.prank(playerB);
        vm.expectRevert(abi.encodeWithSelector(LotteryFinalizationFacet.PrizeAlreadyClaimed.selector, 1));
        finalization.claimWinnings(1, playerB);

        vm.prank(playerA);
        finalization.claimPlayerRewards(1, playerA);
        vm.prank(playerA);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryFinalizationFacet.PlayerRewardAlreadyClaimed.selector, 1, playerA)
        );
        finalization.claimPlayerRewards(1, playerA);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(LotteryFinalizationFacet.PlayerRewardUnavailable.selector, 1, outsider));
        finalization.claimPlayerRewards(1, outsider);
    }

    function test_RevertWhen_FinalizationIsEarlyOrRepeated() public {
        _sellOut();
        vm.prank(playerA);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryFinalizationFacet.RoundNotFinalized.selector, 1, RoundStatus.Closed)
        );
        finalization.claimPlayerRewards(1, playerA);

        vm.prank(playerA);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryFinalizationFacet.RoundNotFinalized.selector, 1, RoundStatus.Closed)
        );
        finalization.claimWinnings(1, playerA);

        vm.expectRevert(
            abi.encodeWithSelector(
                LotteryFinalizationFacet.RoundNotReadyForFinalization.selector, 1, RoundStatus.Closed
            )
        );
        finalization.finalizeLottery(1);

        _acceptRandomness(2);
        finalization.finalizeLottery(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LotteryFinalizationFacet.RoundNotReadyForFinalization.selector, 1, RoundStatus.Finalized
            )
        );
        finalization.finalizeLottery(1);
    }

    function test_RevertWhen_NonWinnerClaimsPrize() public {
        _sellOut();
        _acceptRandomness(0);
        finalization.finalizeLottery(1);

        vm.prank(playerB);
        vm.expectRevert(abi.encodeWithSelector(LotteryFinalizationFacet.NotLotteryWinner.selector, 1, playerB, playerA));
        finalization.claimWinnings(1, playerB);
    }

    function test_PrizeTransferFailureRollsBackClaimAndLiability() public {
        _sellOut();
        _acceptRandomness(0);
        finalization.finalizeLottery(1);
        RejectingPrizeToken rejectingWeth = new RejectingPrizeToken();
        rejectingWeth.mint(address(diamond), 2.5 ether);
        stateHarness.setWeth(address(rejectingWeth));

        vm.prank(playerA);
        vm.expectRevert(bytes("prize rejected"));
        finalization.claimWinnings(1, receiver);

        assertFalse(views.round(1).prizeClaimed);
        (uint256 winnerLiability,) = stateHarness.aggregateLiabilities();
        assertEq(winnerLiability, 2.5 ether);
    }

    function test_PlayerMintMismatchRollsBackClaimAndLiability() public {
        _sellOut();
        _acceptRandomness(0);
        finalization.finalizeLottery(1);
        ShortMintPlayerRewardToken shortToken = new ShortMintPlayerRewardToken();
        stateHarness.setToken(address(shortToken));

        vm.prank(playerA);
        vm.expectRevert(
            abi.encodeWithSelector(
                LotteryFinalizationFacet.PlayerRewardMintMismatch.selector, 20 ether, 20 ether - 1, 20 ether - 1
            )
        );
        finalization.claimPlayerRewards(1, playerA);

        assertFalse(views.playerRewardClaimed(1, playerA));
        assertEq(views.round(1).unclaimedPlayerRewardLiability, 50 ether);
        (, uint256 playerLiability) = stateHarness.aggregateLiabilities();
        assertEq(playerLiability, 50 ether);
        assertEq(shortToken.totalSupply(), 0);
    }

    function test_RevertWhen_ClaimReceiverIsProtocolAddress() public {
        _sellOut();
        _acceptRandomness(0);
        finalization.finalizeLottery(1);

        vm.prank(playerA);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryFinalizationFacet.InvalidLotteryClaimReceiver.selector, address(diamond))
        );
        finalization.claimWinnings(1, address(diamond));
    }

    function _sellOut() private {
        vm.prank(playerA);
        ticketing.buyTickets{value: 2 * (TICKET_PRICE + OPERATIONS_FEE)}(2);
        vm.prank(playerB);
        ticketing.buyTickets{value: 3 * (TICKET_PRICE + OPERATIONS_FEE)}(3);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.Closed));
    }

    function _acceptRandomness(uint256 word) private {
        vm.prank(requester);
        uint256 requestId = randomness.requestRandomness(1);
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        wrapper.fulfill(requestId, words);
    }

    function _configuration(uint256 target) private pure returns (RoundConfiguration memory configuration) {
        configuration.ticketPrice = TICKET_PRICE;
        configuration.ticketOperationsFee = OPERATIONS_FEE;
        configuration.playerRewardRate = PLAYER_REWARD_RATE;
        configuration.ticketTarget = target;
        configuration.maxVrfCost = 0.5 ether;
        configuration.vrfTimeoutBlocks = 10 minutes;
        configuration.requestCallerReward = 0.1 ether;
        configuration.finalizationCallerReward = 0.3 ether;
        configuration.winnerShareBps = 5_000;
        configuration.nftShareBps = 3_000;
        configuration.treasuryShareBps = 1_000;
        configuration.buybackShareBps = 1_000;
        configuration.operationsReserveCap = 1 ether;
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

    function _ticketSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = LotteryTicketFacet.buyTickets.selector;
        selectors[1] = LotteryTicketFacet.ticketQuote.selector;
        selectors[2] = LotteryTicketFacet.buyTicketsWithBuilder.selector;
        selectors[3] = LotteryTicketFacet.builderTicketQuote.selector;
    }

    function _vrfSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = LotteryVRFFacet.requestRandomness.selector;
        selectors[1] = LotteryVRFFacet.rawFulfillRandomWords.selector;
    }

    function _finalizationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = LotteryFinalizationFacet.finalizeLottery.selector;
        selectors[1] = LotteryFinalizationFacet.claimWinnings.selector;
        selectors[2] = LotteryFinalizationFacet.claimPlayerRewards.selector;
        selectors[3] = LotteryFinalizationFacet.expireLottery.selector;
        selectors[4] = LotteryFinalizationFacet.claimExpiredRoundRefund.selector;
    }

    function _viewSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = LotteryViewFacet.currentRoundId.selector;
        selectors[1] = LotteryViewFacet.round.selector;
        selectors[2] = LotteryViewFacet.remainingTickets.selector;
        selectors[3] = LotteryViewFacet.ticketBatchCount.selector;
        selectors[4] = LotteryViewFacet.ticketBatch.selector;
        selectors[5] = LotteryViewFacet.playerTickets.selector;
        selectors[6] = LotteryViewFacet.playerRewardClaimed.selector;
        selectors[7] = LotteryViewFacet.playerRewardEntitlement.selector;
        selectors[8] = LotteryViewFacet.requestRecord.selector;
        selectors[9] = LotteryViewFacet.expiredRoundRefund.selector;
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
        selectors = new bytes4[](5);
        selectors[0] = LotteryFinalizationStateHarness.initializeLotteryState.selector;
        selectors[1] = LotteryFinalizationStateHarness.setNextRoundConfiguration.selector;
        selectors[2] = LotteryFinalizationStateHarness.setToken.selector;
        selectors[3] = LotteryFinalizationStateHarness.setWeth.selector;
        selectors[4] = LotteryFinalizationStateHarness.aggregateLiabilities.selector;
    }

    function _builderSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = bytes4(keccak256("MAX_BUILDER_FEE_BPS()"));
        selectors[1] = BuilderFeesFacet.approveBuilder.selector;
        selectors[2] = BuilderFeesFacet.revokeBuilder.selector;
        selectors[3] = BuilderFeesFacet.claimBuilderFees.selector;
        selectors[4] = BuilderFeesFacet.settleBuilderFees.selector;
        selectors[5] = BuilderFeesFacet.builderApproval.selector;
        selectors[6] = BuilderFeesFacet.builderCredit.selector;
        selectors[7] = BuilderFeesFacet.totalBuilderFeeLiability.selector;
        selectors[8] = BuilderFeesFacet.provisionalBuilderCredit.selector;
    }
}
