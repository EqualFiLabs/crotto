// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {CrottoFacet} from "../../src/diamond/CrottoFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {GovernanceFacet} from "../../src/diamond/facets/GovernanceFacet.sol";
import {LotteryTicketFacet} from "../../src/diamond/facets/LotteryTicketFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/diamond/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibBuybackStorage} from "../../src/libraries/storage/LibBuybackStorage.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "../../src/libraries/storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "../../src/libraries/storage/LibRewardsStorage.sol";
import {LibTreasuryStorage} from "../../src/libraries/storage/LibTreasuryStorage.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";
import {
    ActivationConfiguration,
    GovernanceInitialization,
    HookConfiguration,
    ImmutableConfiguration,
    RewardBook,
    Round,
    RoundConfiguration,
    RoundStatus,
    TicketBatch
} from "../../src/types/CrottoTypes.sol";

contract LotteryHookProbe {
    address public diamond;
    address public activationToken;
    address public weth;
    address public poolManager;
    int24 public canonicalTickSpacing;
    uint256 public initialTokenPerWethWad;
    uint16 public maxCombinedHookFeeBps;
    HookConfiguration private storedConfiguration;

    function configureBindings(address diamond_, address token_, address weth_) external {
        diamond = diamond_;
        activationToken = token_;
        weth = weth_;
        poolManager = address(this);
        canonicalTickSpacing = 60;
        initialTokenPerWethWad = 10_000 ether;
        maxCombinedHookFeeBps = 200;
    }

    function crottoDiamond() external view returns (address) {
        return diamond;
    }

    function setHookConfiguration(HookConfiguration calldata configuration) external {
        require(msg.sender == diamond);
        storedConfiguration = configuration;
    }
}

contract LotteryActivationTokenProbe {
    address public immutable crottoDiamond;
    address public immutable canonicalHook;

    constructor(address diamond_, address hook_) {
        crottoDiamond = diamond_;
        canonicalHook = hook_;
    }
}

contract ShortMintWeth is ERC20 {
    constructor() ERC20("Short WETH", "sWETH") {}

    function deposit() external payable {
        if (msg.value != 0) _mint(msg.sender, msg.value - 1);
    }
}

contract RejectingTransferWeth is ERC20 {
    constructor() ERC20("Rejecting WETH", "rWETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("transfer rejected");
    }
}

contract LotteryTicketStateFacet {
    function operationsReserve() external view returns (uint256) {
        return LibTreasuryStorage.layout().operationsReserveEth;
    }

    function bootstrapWeth() external view returns (uint256) {
        return LibPOLStorage.layout().bootstrapWeth;
    }

    function buybackState() external view returns (uint256 wethReserve, uint256 totalTicketsSold) {
        LibBuybackStorage.Layout storage state = LibBuybackStorage.layout();
        return (state.wethReserve, state.totalTicketsSold);
    }

    function winnerLiability() external view returns (uint256) {
        return LibLotteryStorage.layout().totalWinnerPoolWethLiability;
    }

    function wethRewardBook() external view returns (RewardBook memory) {
        return LibRewardsStorage.layout().wethBook;
    }

    function totalActiveWeight() external view returns (uint256) {
        return LibRewardsStorage.layout().totalActiveWeight;
    }

    function setTotalActiveWeight(uint256 weight) external {
        // Synthetic setup for an otherwise economically expensive routing branch.
        LibRewardsStorage.layout().totalActiveWeight = weight;
    }

    function setPolInitialized(bool initialized) external {
        // Synthetic setup for the post-bootstrap routing branch.
        LibPOLStorage.layout().initialized = initialized;
    }

    function setWeth(address weth) external {
        // Synthetic dependency substitution for atomic failure-path coverage.
        LibGovernanceStorage.layout().immutableConfiguration.weth = weth;
    }
}

contract LotteryTicketingTest is Test {
    uint256 private constant TICKET_PRICE = 101;
    uint256 private constant OPERATIONS_FEE = 0.01 ether;
    uint256 private constant TICKET_TARGET = 10;

    address private player = makeAddr("player");
    address private treasury = makeAddr("treasury");
    address private guardian = makeAddr("guardian");

    WETH9 private weth;
    LotteryHookProbe private hook;
    CrottoDiamond private diamond;
    ICrotto private lottery;
    LotteryTicketFacet private ticketing;
    LotteryViewFacet private views;
    LotteryTicketStateFacet private stateView;
    ICrottoGovernance private governance;

    function setUp() public {
        vm.chainId(31_337);
        weth = new WETH9();
        hook = new LotteryHookProbe();

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        GovernanceFacet governanceFacet = new GovernanceFacet();
        LotteryTicketFacet ticketFacet = new LotteryTicketFacet();
        LotteryViewFacet viewFacet = new LotteryViewFacet();
        LotteryTicketStateFacet stateFacet = new LotteryTicketStateFacet();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = _facetCut(address(cutFacet), _cutSelectors());
        cuts[1] = _facetCut(address(loupeFacet), _loupeSelectors());
        cuts[2] = _facetCut(address(ownershipFacet), _ownershipSelectors());
        cuts[3] = _facetCut(address(governanceFacet), _governanceSelectors());
        cuts[4] = _facetCut(address(ticketFacet), _ticketSelectors());
        cuts[5] = _facetCut(address(viewFacet), _viewSelectors());
        cuts[6] = _facetCut(address(stateFacet), _stateSelectors());

        address predictedDiamond = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        RewardNFT rewardNft = new RewardNFT(predictedDiamond, 10_000);
        LotteryActivationTokenProbe activationToken = new LotteryActivationTokenProbe(predictedDiamond, address(hook));
        hook.configureBindings(predictedDiamond, address(activationToken), address(weth));

        GovernanceInitialization memory initialization = _initialization(address(rewardNft), address(activationToken));
        diamond = new CrottoDiamond(
            address(this),
            cuts,
            address(initializer),
            abi.encodeCall(CrottoDiamondInit.initializeGovernance, (initialization))
        );

        lottery = ICrotto(address(diamond));
        ticketing = LotteryTicketFacet(address(diamond));
        views = LotteryViewFacet(address(diamond));
        stateView = LotteryTicketStateFacet(address(diamond));
        governance = ICrottoGovernance(address(diamond));
        vm.deal(player, 100 ether);
    }

    function test_PurchaseWrapsAndRoutesEveryAccountingClassExactly() public {
        uint256 requiredPayment = TICKET_PRICE * 2 + OPERATIONS_FEE * 2;
        vm.expectEmit(true, true, false, true, address(diamond));
        emit ICrotto.TicketsPurchased(1, player, 2, 0, 2, 202, 0.02 ether, 20, 2);
        vm.prank(player);
        lottery.buyTickets{value: requiredPayment}(2);

        Round memory storedRound = views.round(1);
        assertEq(storedRound.ticketCount, 2);
        assertEq(storedRound.winnerPoolWeth, 101);
        assertEq(stateView.winnerLiability(), 101);
        assertEq(views.remainingTickets(1), 8);
        assertEq(views.playerTickets(1, player), 2);
        assertEq(views.ticketBatchCount(1), 1);
        TicketBatch memory batch = views.ticketBatch(1, 0);
        assertEq(batch.endExclusive, 2);
        assertEq(batch.buyer, player);

        (uint256 buybackReserve, uint256 totalTicketsSold) = stateView.buybackState();
        assertEq(buybackReserve, 20);
        assertEq(totalTicketsSold, 2);
        assertEq(stateView.bootstrapWeth(), 60);
        assertEq(stateView.operationsReserve(), 0.02 ether);
        assertEq(address(diamond).balance, 0.02 ether);
        assertEq(weth.balanceOf(treasury), 21);
        assertEq(weth.balanceOf(address(diamond)), 181);
        assertEq(
            weth.balanceOf(address(diamond)), storedRound.winnerPoolWeth + stateView.bootstrapWeth() + buybackReserve
        );
    }

    function test_EligibleRewardNftsReceiveOnlyCurrentPurchaseShare() public {
        stateView.setTotalActiveWeight(10);

        _buy(player, 1);

        RewardBook memory book = stateView.wethRewardBook();
        assertEq(book.indexedAmount, 30);
        assertEq(stateView.bootstrapWeth(), 0);
        (uint256 buybackReserve,) = stateView.buybackState();
        assertEq(buybackReserve, 10);
        assertEq(weth.balanceOf(treasury), 11);
        assertEq(weth.balanceOf(address(diamond)), 90);
        assertEq(weth.balanceOf(address(diamond)), views.round(1).winnerPoolWeth + book.indexedAmount + buybackReserve);
    }

    function test_InactivePostPolShareRoutesDirectlyToTreasury() public {
        stateView.setPolInitialized(true);

        _buy(player, 1);

        assertEq(stateView.bootstrapWeth(), 0);
        assertEq(stateView.wethRewardBook().indexedAmount, 0);
        (uint256 buybackReserve,) = stateView.buybackState();
        assertEq(buybackReserve, 10);
        assertEq(weth.balanceOf(treasury), 41);
        assertEq(weth.balanceOf(address(diamond)), 60);
    }

    function test_TreasuryReceiverChangeAppliesOnlyToFuturePurchases() public {
        address nextTreasury = makeAddr("nextTreasury");
        _buy(player, 1);
        uint256 deliveredBeforeChange = weth.balanceOf(treasury);

        governance.setTreasuryReceiver(nextTreasury);
        _buy(player, 1);

        assertEq(weth.balanceOf(treasury), deliveredBeforeChange);
        assertEq(weth.balanceOf(nextTreasury), deliveredBeforeChange);
    }

    function test_ExactSelloutClosesRoundAndRejectsFurtherPurchases() public {
        _buy(player, TICKET_TARGET);

        Round memory storedRound = views.round(1);
        assertEq(uint8(storedRound.status), uint8(RoundStatus.Closed));
        assertEq(storedRound.ticketCount, TICKET_TARGET);
        assertEq(views.remainingTickets(1), 0);
        assertEq(storedRound.winnerPoolWeth, 505);
        assertEq(stateView.bootstrapWeth(), 303);
        (uint256 buybackReserve, uint256 totalTicketsSold) = stateView.buybackState();
        assertEq(buybackReserve, 101);
        assertEq(totalTicketsSold, TICKET_TARGET);
        assertEq(weth.balanceOf(treasury), 101);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.RoundNotOpen.selector, 1, RoundStatus.Closed));
        lottery.buyTickets{value: TICKET_PRICE + OPERATIONS_FEE}(1);
    }

    function test_TicketQuoteMatchesExactRequiredPayment() public view {
        (uint256 ticketPriceEth, uint256 operationsFeeEth, uint256 totalEth) = ticketing.ticketQuote(1, 3);
        assertEq(ticketPriceEth, 303);
        assertEq(operationsFeeEth, 0.03 ether);
        assertEq(totalEth, 303 + 0.03 ether);
    }

    function test_RevertWhen_QuantityIsZeroOrExceedsRemaining() public {
        vm.prank(player);
        vm.expectRevert(LotteryTicketFacet.InvalidTicketQuantity.selector);
        lottery.buyTickets(0);

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryTicketFacet.TicketQuantityExceedsRemaining.selector, 11, TICKET_TARGET)
        );
        lottery.buyTickets(11);

        vm.expectRevert(LotteryTicketFacet.InvalidTicketQuantity.selector);
        ticketing.ticketQuote(1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(LotteryTicketFacet.TicketQuantityExceedsRemaining.selector, 11, TICKET_TARGET)
        );
        ticketing.ticketQuote(1, 11);
    }

    function test_RevertWhen_PaymentIsNotExactWithoutChangingState() public {
        uint256 requiredPayment = TICKET_PRICE + OPERATIONS_FEE;
        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                LotteryTicketFacet.IncorrectTicketPayment.selector, requiredPayment, requiredPayment - 1
            )
        );
        lottery.buyTickets{value: requiredPayment - 1}(1);

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                LotteryTicketFacet.IncorrectTicketPayment.selector, requiredPayment, requiredPayment + 1
            )
        );
        lottery.buyTickets{value: requiredPayment + 1}(1);

        assertEq(views.round(1).ticketCount, 0);
        assertEq(address(diamond).balance, 0);
        assertEq(weth.balanceOf(address(diamond)), 0);
        assertEq(stateView.operationsReserve(), 0);
        (uint256 reserve, uint256 sold) = stateView.buybackState();
        assertEq(reserve, 0);
        assertEq(sold, 0);
    }

    function test_RevertWhen_TicketPurchasesArePaused() public {
        ICrottoGovernance(address(diamond)).pauseActions(CrottoConstants.PAUSE_TICKET_PURCHASES);

        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(CrottoFacet.ActionPaused.selector, CrottoConstants.PAUSE_TICKET_PURCHASES)
        );
        lottery.buyTickets{value: TICKET_PRICE + OPERATIONS_FEE}(1);
    }

    function test_RevertWhen_RoundQuoteDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.UnknownRound.selector, 0));
        ticketing.ticketQuote(0, 1);
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.UnknownRound.selector, 2));
        ticketing.ticketQuote(2, 1);
    }

    function test_RevertWhen_TicketPurchasePrecedesRoundInitialization() public {
        LotteryTicketFacet ticketFacet = new LotteryTicketFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LotteryTicketFacet.buyTickets.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _facetCut(address(ticketFacet), selectors);
        CrottoDiamond uninitializedDiamond = new CrottoDiamond(address(this), cuts, address(0), bytes(""));

        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.UnknownRound.selector, 0));
        LotteryTicketFacet(address(uninitializedDiamond)).buyTickets(1);
    }

    function testFuzz_PurchaseAllocationConservesWrappedValue(uint256 quantity, bool activeNfts, bool polInitialized)
        public
    {
        quantity = bound(quantity, 1, TICKET_TARGET);
        if (activeNfts) stateView.setTotalActiveWeight(10);
        else if (polInitialized) stateView.setPolInitialized(true);

        _buy(player, quantity);

        uint256 ticketValue = TICKET_PRICE * quantity;
        uint256 winnerAmount = ticketValue * 5_000 / CrottoConstants.BPS;
        uint256 nftAmount = ticketValue * 3_000 / CrottoConstants.BPS;
        uint256 buybackAmount = ticketValue * 1_000 / CrottoConstants.BPS;
        uint256 treasuryAmount = ticketValue - winnerAmount - nftAmount - buybackAmount;
        uint256 retainedWeth = winnerAmount + buybackAmount;
        if (activeNfts) retainedWeth += nftAmount;
        else if (polInitialized) treasuryAmount += nftAmount;
        else retainedWeth += nftAmount;

        assertEq(weth.balanceOf(address(diamond)), retainedWeth);
        assertEq(weth.balanceOf(treasury), treasuryAmount);
        assertEq(retainedWeth + treasuryAmount, ticketValue);
        assertEq(stateView.operationsReserve(), OPERATIONS_FEE * quantity);
        assertEq(address(diamond).balance, OPERATIONS_FEE * quantity);
        (uint256 reserve, uint256 sold) = stateView.buybackState();
        assertEq(reserve, buybackAmount);
        assertEq(sold, quantity);
    }

    function test_RevertWhen_WethDepositDoesNotMintExactValue() public {
        ShortMintWeth malformedWeth = new ShortMintWeth();
        stateView.setWeth(address(malformedWeth));

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(LotteryTicketFacet.UnexpectedWethDeposit.selector, TICKET_PRICE, 100));
        lottery.buyTickets{value: TICKET_PRICE + OPERATIONS_FEE}(1);

        _assertPurchaseStateUnchanged(address(malformedWeth));
    }

    function test_RevertWhen_TreasuryWethDeliveryFails() public {
        RejectingTransferWeth malformedWeth = new RejectingTransferWeth();
        stateView.setWeth(address(malformedWeth));

        vm.prank(player);
        vm.expectRevert(bytes("transfer rejected"));
        lottery.buyTickets{value: TICKET_PRICE + OPERATIONS_FEE}(1);

        _assertPurchaseStateUnchanged(address(malformedWeth));
    }

    function _buy(address buyer, uint256 quantity) private {
        (,, uint256 requiredPayment) = ticketing.ticketQuote(1, quantity);
        vm.prank(buyer);
        lottery.buyTickets{value: requiredPayment}(quantity);
    }

    function _assertPurchaseStateUnchanged(address wethAddress) private view {
        assertEq(views.round(1).ticketCount, 0);
        assertEq(views.ticketBatchCount(1), 0);
        assertEq(stateView.operationsReserve(), 0);
        assertEq(stateView.bootstrapWeth(), 0);
        assertEq(address(diamond).balance, 0);
        assertEq(IERC20(wethAddress).balanceOf(address(diamond)), 0);
        (uint256 reserve, uint256 sold) = stateView.buybackState();
        assertEq(reserve, 0);
        assertEq(sold, 0);
    }

    function _initialization(address rewardNft, address activationToken)
        private
        view
        returns (GovernanceInitialization memory initialization)
    {
        initialization = GovernanceInitialization({
            immutableConfiguration: ImmutableConfiguration({
                activationToken: activationToken,
                rewardNFT: rewardNft,
                weth: address(weth),
                vrfWrapper: address(hook),
                uniswapV4PoolManager: address(hook),
                canonicalHook: address(hook),
                rewardNFTMaxSupply: 10_000,
                vaultPrice: 1_000 ether,
                requiredBootstrapWeth: 300,
                initialTokenPerWethWad: 10_000 ether,
                maxCombinedHookFeeBps: 200,
                canonicalTickSpacing: 60,
                vrfCallbackGasLimit: 250_000,
                vrfRequestConfirmations: 3
            }),
            roundConfiguration: RoundConfiguration({
                ticketPrice: TICKET_PRICE,
                ticketOperationsFee: OPERATIONS_FEE,
                playerRewardRate: 10 ether,
                ticketTarget: TICKET_TARGET,
                maxVrfCost: 0.02 ether,
                vrfRetryDelay: 10 minutes,
                requestCallerReward: 0.01 ether,
                finalizationCallerReward: 0.01 ether,
                winnerShareBps: 5_000,
                nftShareBps: 3_000,
                treasuryShareBps: 1_000,
                buybackShareBps: 1_000
            }),
            activationConfiguration: ActivationConfiguration({
                costs: [uint256(100 ether), 200 ether, 300 ether],
                destinationWeights: [uint256(1), 2, 3],
                burnShareBps: 2_500,
                nftShareBps: 2_500,
                treasuryShareBps: 5_000
            }),
            hookConfiguration: HookConfiguration({
                inputFeeBps: 50, outputFeeBps: 50, polShareBps: 5_000, nftShareBps: 4_000, treasuryShareBps: 1_000
            }),
            treasuryReceiver: treasury,
            guardian: guardian
        });
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

    function _governanceSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = ICrottoGovernance.setRoundConfiguration.selector;
        selectors[1] = ICrottoGovernance.setActivationConfiguration.selector;
        selectors[2] = ICrottoGovernance.setHookConfiguration.selector;
        selectors[3] = ICrottoGovernance.setTreasuryReceiver.selector;
        selectors[4] = ICrottoGovernance.setGuardian.selector;
        selectors[5] = ICrottoGovernance.pauseActions.selector;
        selectors[6] = ICrottoGovernance.unpauseActions.selector;
        selectors[7] = ICrottoGovernance.treasuryReceiver.selector;
        selectors[8] = ICrottoGovernance.guardian.selector;
        selectors[9] = ICrottoGovernance.pausedActions.selector;
    }

    function _ticketSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = LotteryTicketFacet.buyTickets.selector;
        selectors[1] = LotteryTicketFacet.ticketQuote.selector;
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

    function _stateSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = LotteryTicketStateFacet.operationsReserve.selector;
        selectors[1] = LotteryTicketStateFacet.bootstrapWeth.selector;
        selectors[2] = LotteryTicketStateFacet.buybackState.selector;
        selectors[3] = LotteryTicketStateFacet.wethRewardBook.selector;
        selectors[4] = LotteryTicketStateFacet.totalActiveWeight.selector;
        selectors[5] = LotteryTicketStateFacet.setTotalActiveWeight.selector;
        selectors[6] = LotteryTicketStateFacet.setPolInitialized.selector;
        selectors[7] = LotteryTicketStateFacet.setWeth.selector;
        selectors[8] = LotteryTicketStateFacet.winnerLiability.selector;
    }
}
