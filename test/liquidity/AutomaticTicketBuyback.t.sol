// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {BuilderFeesFacet} from "../../src/diamond/facets/BuilderFeesFacet.sol";
import {BuybackSettlementFacet} from "../../src/diamond/facets/BuybackSettlementFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {GovernanceFacet} from "../../src/diamond/facets/GovernanceFacet.sol";
import {LotteryFinalizationFacet} from "../../src/diamond/facets/LotteryFinalizationFacet.sol";
import {LotteryTicketFacet} from "../../src/diamond/facets/LotteryTicketFacet.sol";
import {LotteryVRFFacet} from "../../src/diamond/facets/LotteryVRFFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {POLInitializationFacet} from "../../src/diamond/facets/POLInitializationFacet.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {RewardActivationFacet} from "../../src/diamond/facets/RewardActivationFacet.sol";
import {RewardClaimsFacet} from "../../src/diamond/facets/RewardClaimsFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoBuilderFees} from "../../src/interfaces/ICrottoBuilderFees.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {IAutomaticTicketBuyback} from "../../src/interfaces/IAutomaticTicketBuyback.sol";
import {IPOLInitialization} from "../../src/interfaces/IPOLInitialization.sol";
import {LibAutomaticBuyback} from "../../src/libraries/LibAutomaticBuyback.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {CrottoSwapFeeHook} from "../../src/liquidity/CrottoSwapFeeHook.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";
import {
    ActivationConfiguration,
    BuybackConfiguration,
    GovernanceInitialization,
    HookConfiguration,
    ImmutableConfiguration,
    POLAccountingView,
    RoundConfiguration
} from "../../src/types/CrottoTypes.sol";
import {IPoolDonateRouter, IPoolSwapRouter} from "./CrottoSwapFeeHook.t.sol";

interface IV4BuybackTestDeployment {
    function manager() external view returns (IPoolManager);

    function donateRouter() external view returns (address);

    function swapRouter() external view returns (address);
}

contract BuybackVrfWrapperProbe {
    uint256 public price = 0.01 ether;
    uint256 public nextRequestId = 1;
    address public latestConsumer;

    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) {
        return price;
    }

    function requestRandomWordsInNative(uint32, uint16, uint32, bytes calldata)
        external
        payable
        returns (uint256 requestId)
    {
        require(msg.value == price, "wrong price");
        latestConsumer = msg.sender;
        requestId = nextRequestId++;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        ICrotto(latestConsumer).rawFulfillRandomWords(requestId, words);
    }
}

interface IRewardLifecycleHarness is ICrottoRewards {
    function mintRewardNFT(address receiver) external returns (uint256 tokenId);
}

contract RewardLifecycleHarnessFacet is RewardActivationFacet {
    function mintRewardNFT(address receiver) external returns (uint256 tokenId) {
        IRewardNFT nft = IRewardNFT(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT);
        tokenId = nft.mintedSupply() + 1;
        _checkpointNftRewards(tokenId);
        assert(nft.mint(receiver) == tokenId);
    }
}

abstract contract AutomaticTicketBuybackFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant TICKET_PRICE = 1 ether;
    uint256 internal constant OPERATIONS_FEE = 0.01 ether;
    uint256 internal constant TICKET_TARGET = 100;
    uint256 internal constant REQUIRED_BOOTSTRAP_WETH = 30 ether;
    uint256 internal constant TOKEN_PER_WETH_WAD = 10_000 ether;
    int24 internal constant TICK_SPACING = 60;

    bytes32 internal constant SWAP_EVENT_SIGNATURE =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant BUYBACK_EVENT_SIGNATURE =
        keccak256("PendingBuybackExecuted(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 private constant HOOK_FEE_EVENT_SIGNATURE =
        keccak256("SwapLegFeeAccrued(bytes32,address,bool,uint256,uint256,uint256,uint256)");

    address internal player = makeAddr("player");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");

    CrottoDiamond internal diamond;
    ActivationToken internal token;
    RewardNFT internal rewardNft;
    BuybackVrfWrapperProbe internal vrfWrapper;
    IERC20 internal weth;
    CrottoSwapFeeHook internal hook;
    IPoolManager internal manager;
    IPoolDonateRouter internal donateRouter;
    IPoolSwapRouter internal swapRouter;
    ICrotto internal lottery;
    ICrottoBuilderFees internal builders;
    ICrottoGovernance internal governance;
    IPOLInitialization internal pol;
    LotteryViewFacet internal views;
    PoolId internal poolId;

    function _deployProtocol(bool wethIsCurrency0) internal {
        vm.chainId(31_337);
        IV4BuybackTestDeployment v4 =
            IV4BuybackTestDeployment(_deployArtifact("out/V4TestDeployment.sol/V4TestDeployment.json"));
        manager = v4.manager();
        donateRouter = IPoolDonateRouter(v4.donateRouter());
        swapRouter = IPoolSwapRouter(v4.swapRouter());

        WETH9 wethImplementation = new WETH9();
        address wethAddress = wethIsCurrency0 ? address(uint160(0x1000)) : address(uint160(type(uint160).max - 0x1000));
        vm.etch(wethAddress, address(wethImplementation).code);
        weth = IERC20(wethAddress);

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamondCut.FacetCut[] memory shellCut = new IDiamondCut.FacetCut[](1);
        shellCut[0] = _facetCut(address(cutFacet), _artifactSelectors("out/DiamondCutFacet.sol/DiamondCutFacet.json"));
        diamond = new CrottoDiamond(address(this), shellCut, address(0), "");

        rewardNft = new RewardNFT(address(diamond), _rewardNftMaxSupply());
        address expectedToken = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory hookConstructorArgs = abi.encode(
            manager, address(diamond), expectedToken, wethAddress, TICK_SPACING, TOKEN_PER_WETH_WAD, uint16(100)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(CrottoSwapFeeHook).creationCode, hookConstructorArgs);

        token = new ActivationToken(treasury, address(diamond), expectedHook);
        assertEq(address(token), expectedToken);
        hook = new CrottoSwapFeeHook{salt: salt}(
            manager, address(diamond), address(token), wethAddress, TICK_SPACING, TOKEN_PER_WETH_WAD, 100
        );
        assertEq(address(hook), expectedHook);
        assertEq(
            Currency.unwrap(LibCanonicalPool.key(address(token), wethAddress, address(hook), TICK_SPACING).currency0),
            wethIsCurrency0 ? wethAddress : address(token)
        );

        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        GovernanceFacet governanceFacet = new GovernanceFacet();
        BuilderFeesFacet builderFacet = new BuilderFeesFacet();
        LotteryTicketFacet ticketFacet = new LotteryTicketFacet();
        LotteryViewFacet viewFacet = new LotteryViewFacet();
        POLInitializationFacet polFacet = new POLInitializationFacet();
        RewardAccountingFacet accountingFacet = new RewardAccountingFacet();
        RewardLifecycleHarnessFacet rewardLifecycleFacet = new RewardLifecycleHarnessFacet();
        RewardClaimsFacet rewardClaimsFacet = new RewardClaimsFacet();
        BuybackSettlementFacet settlementFacet = new BuybackSettlementFacet();
        LotteryVRFFacet vrfFacet = new LotteryVRFFacet();
        LotteryFinalizationFacet finalizationFacet = new LotteryFinalizationFacet();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](13);
        cuts[0] = _facetCut(address(loupeFacet), _artifactSelectors("out/DiamondLoupeFacet.sol/DiamondLoupeFacet.json"));
        cuts[1] = _facetCut(address(ownershipFacet), _artifactSelectors("out/OwnershipFacet.sol/OwnershipFacet.json"));
        cuts[2] =
            _facetCut(address(governanceFacet), _artifactSelectors("out/GovernanceFacet.sol/GovernanceFacet.json"));
        cuts[3] = _facetCut(address(builderFacet), _artifactSelectors("out/BuilderFeesFacet.sol/BuilderFeesFacet.json"));
        cuts[4] =
            _facetCut(address(ticketFacet), _artifactSelectors("out/LotteryTicketFacet.sol/LotteryTicketFacet.json"));
        cuts[5] = _facetCut(address(viewFacet), _artifactSelectors("out/LotteryViewFacet.sol/LotteryViewFacet.json"));
        cuts[6] = _facetCut(
            address(polFacet), _artifactSelectors("out/POLInitializationFacet.sol/POLInitializationFacet.json")
        );
        cuts[7] = _facetCut(
            address(accountingFacet), _artifactSelectors("out/RewardAccountingFacet.sol/RewardAccountingFacet.json")
        );
        cuts[8] = _facetCut(address(rewardLifecycleFacet), _rewardLifecycleSelectors());
        cuts[9] = _facetCut(
            address(rewardClaimsFacet), _artifactSelectors("out/RewardClaimsFacet.sol/RewardClaimsFacet.json")
        );
        cuts[10] = _facetCut(
            address(settlementFacet), _artifactSelectors("out/BuybackSettlementFacet.sol/BuybackSettlementFacet.json")
        );
        cuts[11] = _facetCut(address(vrfFacet), _artifactSelectors("out/LotteryVRFFacet.sol/LotteryVRFFacet.json"));
        cuts[12] = _facetCut(
            address(finalizationFacet),
            _artifactSelectors("out/LotteryFinalizationFacet.sol/LotteryFinalizationFacet.json")
        );

        vrfWrapper = new BuybackVrfWrapperProbe();
        GovernanceInitialization memory initialization =
            _initialization(address(rewardNft), wethAddress, address(vrfWrapper));
        IDiamondCut(address(diamond))
            .diamondCut(
                cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initializeGovernance, (initialization))
            );

        lottery = ICrotto(address(diamond));
        builders = ICrottoBuilderFees(address(diamond));
        governance = ICrottoGovernance(address(diamond));
        pol = IPOLInitialization(address(diamond));
        views = LotteryViewFacet(address(diamond));
        vm.deal(player, 500 ether);
    }

    function _bootstrapPOL() internal {
        _buyTickets(TICKET_TARGET);
        uint256 requestId = lottery.requestRandomness(1);
        vrfWrapper.fulfill(requestId, 0);
        lottery.finalizeLottery(1);
        assertGe(pol.bootstrapPolWeth(), REQUIRED_BOOTSTRAP_WETH);
        assertTrue(pol.canInitializePOL());
        pol.initializePOL();
        assertTrue(pol.polInitialized());
        poolId = pol.canonicalPoolId();
    }

    function _buyTickets(uint256 quantity) internal {
        vm.prank(player);
        lottery.buyTickets{value: (TICKET_PRICE + OPERATIONS_FEE) * quantity}(quantity);
    }

    function _assertOneCanonicalSwap(Vm.Log[] memory logs) internal view {
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics.length != 0
                    && logs[i].topics[0] == SWAP_EVENT_SIGNATURE
            ) {
                assertEq(logs[i].topics[1], PoolId.unwrap(poolId));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(diamond));
                ++swaps;
            }
        }
        assertEq(swaps, 1, "one aggregate canonical swap");
    }

    function _assertBilateralHookFees(Vm.Log[] memory logs) internal view {
        bool sawWeth;
        bool sawToken;
        uint256 feeEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics.length != 0
                    && logs[i].topics[0] == HOOK_FEE_EVENT_SIGNATURE
            ) {
                assertEq(logs[i].topics[1], PoolId.unwrap(poolId));
                address asset = address(uint160(uint256(logs[i].topics[2])));
                if (asset == address(weth)) sawWeth = true;
                if (asset == address(token)) sawToken = true;
                ++feeEvents;
            }
        }
        assertEq(feeEvents, 2, "both fee legs");
        assertTrue(sawWeth && sawToken, "both fee assets");
    }

    function _buybackEvent(Vm.Log[] memory logs, address expectedCaller, address expectedTreasury)
        internal
        returns (uint256 consumed, uint256 tip, uint256 exactWethDebit, uint256 actualOut)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(diamond) && logs[i].topics.length != 0
                    && logs[i].topics[0] == BUYBACK_EVENT_SIGNATURE
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), expectedCaller);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedTreasury);
                assertEq(uint256(logs[i].topics[3]), 1);
                (consumed, tip,,, exactWethDebit, actualOut) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                return (consumed, tip, exactWethDebit, actualOut);
            }
        }
        fail("buyback event missing");
    }

    function _finalizeOpenRound() internal returns (uint256 roundId) {
        roundId = views.currentRoundId();
        uint256 remaining = TICKET_TARGET - views.round(roundId).ticketCount;
        if (remaining != 0) _buyTickets(remaining);
        uint256 requestId = lottery.requestRandomness(roundId);
        vrfWrapper.fulfill(requestId, 0);
        lottery.finalizeLottery(roundId);
    }

    function _initialization(address rewardNftAddress, address wethAddress, address vrfWrapperAddress)
        internal
        view
        returns (GovernanceInitialization memory initialization)
    {
        initialization = GovernanceInitialization({
            immutableConfiguration: ImmutableConfiguration({
                activationToken: address(token),
                rewardNFT: rewardNftAddress,
                weth: wethAddress,
                vrfWrapper: vrfWrapperAddress,
                uniswapV4PoolManager: address(manager),
                canonicalHook: address(hook),
                rewardNFTMaxSupply: _rewardNftMaxSupply(),
                vaultPrice: 1 ether,
                requiredBootstrapWeth: REQUIRED_BOOTSTRAP_WETH,
                initialTokenPerWethWad: TOKEN_PER_WETH_WAD,
                maxCombinedHookFeeBps: 100,
                canonicalTickSpacing: TICK_SPACING,
                vrfCallbackGasLimit: 500_000,
                vrfRequestConfirmations: 3
            }),
            roundConfiguration: RoundConfiguration({
                ticketPrice: TICKET_PRICE,
                ticketOperationsFee: OPERATIONS_FEE,
                playerRewardRate: 100 ether,
                ticketTarget: TICKET_TARGET,
                maxVrfCost: 0.1 ether,
                vrfTimeoutBlocks: 1 hours,
                requestCallerReward: 0.01 ether,
                finalizationCallerReward: 0.01 ether,
                winnerShareBps: 5_000,
                nftShareBps: 3_000,
                treasuryShareBps: 1_000,
                buybackShareBps: 1_000,
                operationsReserveCap: 0.5 ether
            }),
            activationConfiguration: ActivationConfiguration({
                costs: [uint256(1 ether), 2 ether, 3 ether],
                destinationWeights: [uint256(1), 2, 3],
                burnShareBps: 2_500,
                nftShareBps: 2_500,
                treasuryShareBps: 5_000
            }),
            hookConfiguration: HookConfiguration({
                inputFeeBps: 50, outputFeeBps: 50, polShareBps: 5_000, nftShareBps: 4_000, treasuryShareBps: 1_000
            }),
            treasuryReceiver: treasury,
            guardian: guardian,
            buybackConfiguration: BuybackConfiguration({callerTipBps: 10, maximumWethChunk: 0.1 ether})
        });
    }

    function _facetCut(address facet, bytes4[] memory selectors)
        internal
        pure
        returns (IDiamondCut.FacetCut memory cut)
    {
        cut = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _rewardLifecycleSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = RewardActivationFacet.activateNextTier.selector;
        selectors[1] = RewardLifecycleHarnessFacet.mintRewardNFT.selector;
    }

    function _rewardNftMaxSupply() internal pure virtual returns (uint256) {
        return 10_000;
    }

    function _artifactSelectors(string memory artifactPath) internal view returns (bytes4[] memory selectors) {
        // Paths are fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(artifactPath), ".methodIdentifiers");
        selectors = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _deployArtifact(string memory artifact) internal returns (address deployed) {
        bytes memory creationCode = vm.getCode(artifact);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "artifact deployment failed");
    }
}

contract RewardNftRoundSettlementTest is AutomaticTicketBuybackFixture {
    address private nextOwner = makeAddr("nextOwner");

    function setUp() public {
        _deployProtocol(true);
    }

    function test_PurchaseTimeEligibilityMaturesOnlyAfterSuccessfulFinalization() public {
        uint256 tokenId = _mintAndActivateRewardNft();
        _buyTickets(40);

        (uint256 pendingBefore,) = ICrottoRewards(address(diamond)).pendingNFTRewards(tokenId);
        assertEq(pendingBefore, 0, "open-round rewards are provisional");

        vm.prank(player);
        rewardNft.transferFrom(player, nextOwner, tokenId);
        _finalizeOpenRound();

        (uint256 pendingAfter,) = ICrottoRewards(address(diamond)).pendingNFTRewards(tokenId);
        assertEq(pendingAfter, 12 ether, "only pre-transfer purchases mature");
        uint256 receiverBefore = weth.balanceOf(nextOwner);
        vm.prank(nextOwner);
        assertEq(ICrottoRewards(address(diamond)).claimNFTWethReward(tokenId, nextOwner), 12 ether);
        assertEq(weth.balanceOf(nextOwner) - receiverBefore, 12 ether);
    }

    function test_ExpiredRoundDiscardsProvisionalRewardNftRevenue() public {
        uint256 tokenId = _mintAndActivateRewardNft();
        _buyTickets(TICKET_TARGET);
        uint256 timeout = views.round(1).config.vrfTimeoutBlocks;
        vm.roll(block.number + timeout + 1);
        lottery.expireLottery(1);

        (uint256 pending,) = ICrottoRewards(address(diamond)).pendingNFTRewards(tokenId);
        assertEq(pending, 0);
        uint256 receiverBefore = weth.balanceOf(player);
        vm.prank(player);
        assertEq(ICrottoRewards(address(diamond)).claimNFTWethReward(tokenId, player), 0);
        assertEq(weth.balanceOf(player), receiverBefore);
    }

    function _mintAndActivateRewardNft() private returns (uint256 tokenId) {
        IRewardLifecycleHarness rewards = IRewardLifecycleHarness(address(diamond));
        tokenId = rewards.mintRewardNFT(player);
        vm.prank(treasury);
        token.transfer(player, 2 ether);
        vm.prank(player);
        token.approve(address(diamond), type(uint256).max);
        vm.prank(player);
        rewards.activateNextTier(tokenId, 1, 1 ether);
    }
}

contract AutomaticTicketBuybackTest is AutomaticTicketBuybackFixture {
    function setUp() public {
        _deployProtocol(true);
        _bootstrapPOL();
    }

    function test_PermissionlessChunkExecutesOneBuybackAndPreservesAccounting() public {
        _finalizeOpenRound();
        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        uint256 treasuryWethBefore = weth.balanceOf(treasury);
        uint128 lockedBefore = hook.lockedLiquidity();
        uint256 diamondWethBefore = weth.balanceOf(address(diamond));
        uint256 callerWethBefore = weth.balanceOf(player);

        vm.recordLogs();
        vm.prank(player);
        (uint256 consumed, uint256 actualNetTokenOut) =
            IAutomaticTicketBuyback(address(diamond)).executePendingBuyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertOneCanonicalSwap(logs);
        _assertBilateralHookFees(logs);
        (uint256 eventConsumed, uint256 tip, uint256 exactWethDebit, uint256 actualOut) =
            _buybackEvent(logs, player, treasury);
        assertEq(consumed, 0.1 ether);
        assertEq(eventConsumed, consumed);
        assertEq(tip, 0.0001 ether);
        assertEq(exactWethDebit + tip, consumed);
        assertGt(actualOut, 0);
        assertEq(actualNetTokenOut, actualOut);
        assertGe(token.balanceOf(treasury) - treasuryTokenBefore, actualOut);
        assertGt(weth.balanceOf(treasury) - treasuryWethBefore, 0);
        assertEq(diamondWethBefore - weth.balanceOf(address(diamond)), consumed);
        assertEq(weth.balanceOf(player) - callerWethBefore, tip);
        assertGt(hook.lockedLiquidity(), lockedBefore);

        POLAccountingView memory accounting = pol.polAccounting();
        assertGe(token.balanceOf(address(hook)), accounting.pendingToken);
        assertGe(weth.balanceOf(address(hook)), accounting.pendingWeth);
    }

    function test_BuybackExecutesImmediatelyAfterFinalizationWithoutPriceWarmup() public {
        _finalizeOpenRound();
        uint256 pendingBefore = views.protocolAccounting().pendingBuybackWeth;
        uint256 treasuryTokenBefore = token.balanceOf(treasury);

        IAutomaticTicketBuyback(address(diamond)).executePendingBuyback();
        assertEq(views.protocolAccounting().pendingBuybackWeth, pendingBefore - 0.1 ether);
        assertGt(token.balanceOf(treasury), treasuryTokenBefore);
    }

    function test_UnlockCallbackRejectsEveryCallerOutsideAnActiveManagerUnlock() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibAutomaticBuyback.InvalidPoolManagerCaller.selector, player, address(manager))
        );
        vm.prank(player);
        IUnlockCallback(address(diamond)).unlockCallback("");

        vm.expectRevert(LibAutomaticBuyback.InvalidBuybackExecutionContext.selector);
        vm.prank(address(manager));
        IUnlockCallback(address(diamond)).unlockCallback("");
    }

    function test_LiveTreasuryTipAndChunkApplyToTheNextExecution() public {
        _finalizeOpenRound();
        address nextTreasury = makeAddr("nextTreasury");
        uint256 originalTreasuryTokenBefore = token.balanceOf(treasury);
        governance.setTreasuryReceiver(nextTreasury);
        governance.setBuybackConfiguration(BuybackConfiguration({callerTipBps: 25, maximumWethChunk: 0.05 ether}));

        vm.recordLogs();
        IAutomaticTicketBuyback(address(diamond)).executePendingBuyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 consumed, uint256 tip, uint256 exactWethDebit, uint256 actualOut) =
            _buybackEvent(logs, address(this), nextTreasury);
        assertEq(consumed, 0.05 ether);
        assertEq(tip, 0.000125 ether);
        assertEq(exactWethDebit + tip, consumed);
        assertGt(token.balanceOf(nextTreasury), actualOut, "net output plus hook treasury fee");
        assertEq(token.balanceOf(treasury), originalTreasuryTokenBefore, "old receiver is prospective only");
    }

    function test_TicketPauseDoesNotBlockBuybackOrPOLMaintenance() public {
        _finalizeOpenRound();
        governance.pauseActions(1);
        uint256 currentRoundId = views.currentRoundId();
        uint256 ticketCountBefore = views.round(currentRoundId).ticketCount;
        vm.expectRevert();
        _buyTickets(1);
        assertEq(views.round(currentRoundId).ticketCount, ticketCountBefore);

        IAutomaticTicketBuyback(address(diamond)).executePendingBuyback();

        vm.startPrank(treasury);
        token.approve(address(hook), 1_000 ether);
        vm.stopPrank();
        governance.addPOL(treasury, 1_000 ether, 0);
        hook.compoundPOL();
        assertTrue(hook.poolInitialized());
    }
}

contract AutomaticTicketBuybackPrePolTest is AutomaticTicketBuybackFixture {
    function test_PrePolBuybackShareRoutesDirectlyToBootstrapWithoutSwapping() public {
        _deployProtocol(true);
        uint256 treasuryTokenBefore = token.balanceOf(treasury);

        vm.recordLogs();
        _buyTickets(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 managerSwaps;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics.length != 0
                    && logs[i].topics[0] == SWAP_EVENT_SIGNATURE
            ) ++managerSwaps;
        }
        assertEq(managerSwaps, 0);
        assertEq(views.roundSettlement(1).bootstrapPolWeth, 0.4 ether, "provisional bootstrap allocation");
        assertEq(pol.bootstrapPolWeth(), 0, "not committed before finalization");
        assertEq(token.balanceOf(treasury), treasuryTokenBefore);
        assertEq(views.round(1).ticketCount, 1);
    }
}

contract AutomaticTicketBuybackReverseOrderTest is AutomaticTicketBuybackFixture {
    function test_PostPolBuybackWorksWhenWethIsCurrency1() public {
        _deployProtocol(false);
        _bootstrapPOL();
        _finalizeOpenRound();
        uint256 treasuryTokenBefore = token.balanceOf(treasury);

        vm.recordLogs();
        IAutomaticTicketBuyback(address(diamond)).executePendingBuyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertOneCanonicalSwap(logs);
        _assertBilateralHookFees(logs);
        (uint256 consumed,,, uint256 actualOut) = _buybackEvent(logs, address(this), treasury);
        assertEq(consumed, 0.1 ether);
        assertGt(actualOut, 0);
        assertGt(token.balanceOf(treasury), treasuryTokenBefore);
    }
}
