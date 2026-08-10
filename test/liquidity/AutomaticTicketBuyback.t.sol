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
import {BuybackSettlementFacet} from "../../src/diamond/facets/BuybackSettlementFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/diamond/facets/DiamondLoupeFacet.sol";
import {GovernanceFacet} from "../../src/diamond/facets/GovernanceFacet.sol";
import {LotteryTicketFacet} from "../../src/diamond/facets/LotteryTicketFacet.sol";
import {LotteryViewFacet} from "../../src/diamond/facets/LotteryViewFacet.sol";
import {OwnershipFacet} from "../../src/diamond/facets/OwnershipFacet.sol";
import {POLInitializationFacet} from "../../src/diamond/facets/POLInitializationFacet.sol";
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {CrottoDiamondInit} from "../../src/diamond/initializers/CrottoDiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IAutomaticTicketBuyback} from "../../src/interfaces/IAutomaticTicketBuyback.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {ICrottoSwapFeeHook} from "../../src/interfaces/ICrottoSwapFeeHook.sol";
import {IPOLInitialization} from "../../src/interfaces/IPOLInitialization.sol";
import {LibAutomaticBuyback} from "../../src/libraries/LibAutomaticBuyback.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
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
    RoundConfiguration,
    RoundStatus
} from "../../src/types/CrottoTypes.sol";

interface IV4BuybackTestDeployment {
    function manager() external view returns (IPoolManager);
}

contract BuybackVrfWrapperProbe {}

abstract contract AutomaticTicketBuybackFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant TICKET_PRICE = 1 ether;
    uint256 internal constant OPERATIONS_FEE = 0.01 ether;
    uint256 internal constant TICKET_TARGET = 100;
    uint256 internal constant REQUIRED_BOOTSTRAP_WETH = 30 ether;
    uint256 internal constant TOKEN_PER_WETH_WAD = 10_000 ether;
    int24 internal constant TICK_SPACING = 60;

    bytes32 private constant SWAP_EVENT_SIGNATURE =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant BUYBACK_EVENT_SIGNATURE = keccak256(
        "AutomaticTicketBuybackExecuted(uint256,address,address,uint256,uint256,uint256,uint256,uint16,uint256,uint256)"
    );
    bytes32 private constant HOOK_FEE_EVENT_SIGNATURE =
        keccak256("SwapLegFeeAccrued(bytes32,address,bool,uint256,uint256,uint256,uint256)");

    address internal player = makeAddr("player");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");

    CrottoDiamond internal diamond;
    ActivationToken internal token;
    IERC20 internal weth;
    CrottoSwapFeeHook internal hook;
    IPoolManager internal manager;
    ICrotto internal lottery;
    ICrottoGovernance internal governance;
    IPOLInitialization internal pol;
    LotteryViewFacet internal views;
    PoolId internal poolId;

    function _deployProtocol(bool wethIsCurrency0) internal {
        vm.chainId(31_337);
        IV4BuybackTestDeployment v4 =
            IV4BuybackTestDeployment(_deployArtifact("out/V4TestDeployment.sol/V4TestDeployment.json"));
        manager = v4.manager();

        WETH9 wethImplementation = new WETH9();
        address wethAddress = wethIsCurrency0 ? address(uint160(0x1000)) : address(uint160(type(uint160).max - 0x1000));
        vm.etch(wethAddress, address(wethImplementation).code);
        weth = IERC20(wethAddress);

        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamondCut.FacetCut[] memory shellCut = new IDiamondCut.FacetCut[](1);
        shellCut[0] = _facetCut(address(cutFacet), _artifactSelectors("out/DiamondCutFacet.sol/DiamondCutFacet.json"));
        diamond = new CrottoDiamond(address(this), shellCut, address(0), "");

        RewardNFT rewardNft = new RewardNFT(address(diamond), 10_000);
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
        LotteryTicketFacet ticketFacet = new LotteryTicketFacet();
        LotteryViewFacet viewFacet = new LotteryViewFacet();
        POLInitializationFacet polFacet = new POLInitializationFacet();
        RewardAccountingFacet accountingFacet = new RewardAccountingFacet();
        BuybackSettlementFacet settlementFacet = new BuybackSettlementFacet();
        CrottoDiamondInit initializer = new CrottoDiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](8);
        cuts[0] = _facetCut(address(loupeFacet), _artifactSelectors("out/DiamondLoupeFacet.sol/DiamondLoupeFacet.json"));
        cuts[1] = _facetCut(address(ownershipFacet), _artifactSelectors("out/OwnershipFacet.sol/OwnershipFacet.json"));
        cuts[2] =
            _facetCut(address(governanceFacet), _artifactSelectors("out/GovernanceFacet.sol/GovernanceFacet.json"));
        cuts[3] =
            _facetCut(address(ticketFacet), _artifactSelectors("out/LotteryTicketFacet.sol/LotteryTicketFacet.json"));
        cuts[4] = _facetCut(address(viewFacet), _artifactSelectors("out/LotteryViewFacet.sol/LotteryViewFacet.json"));
        cuts[5] = _facetCut(
            address(polFacet), _artifactSelectors("out/POLInitializationFacet.sol/POLInitializationFacet.json")
        );
        cuts[6] = _facetCut(
            address(accountingFacet), _artifactSelectors("out/RewardAccountingFacet.sol/RewardAccountingFacet.json")
        );
        cuts[7] = _facetCut(
            address(settlementFacet), _artifactSelectors("out/BuybackSettlementFacet.sol/BuybackSettlementFacet.json")
        );

        GovernanceInitialization memory initialization =
            _initialization(address(rewardNft), wethAddress, address(new BuybackVrfWrapperProbe()));
        IDiamondCut(address(diamond))
            .diamondCut(
                cuts, address(initializer), abi.encodeCall(CrottoDiamondInit.initializeGovernance, (initialization))
            );

        lottery = ICrotto(address(diamond));
        governance = ICrottoGovernance(address(diamond));
        pol = IPOLInitialization(address(diamond));
        views = LotteryViewFacet(address(diamond));
        vm.deal(player, 200 ether);
    }

    function _bootstrapPOL() internal {
        _buyTickets(75);
        assertEq(pol.bootstrapPolWeth(), REQUIRED_BOOTSTRAP_WETH);
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

    function _buybackEvent(Vm.Log[] memory logs)
        internal
        returns (uint256 grossBudget, uint256 exactWethDebit, uint256 minimumOut, uint256 actualOut)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(diamond) && logs[i].topics.length != 0
                    && logs[i].topics[0] == BUYBACK_EVENT_SIGNATURE
            ) {
                assertEq(uint256(logs[i].topics[1]), 1);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), player);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), treasury);
                uint16 slippageBps;
                (grossBudget,,, exactWethDebit, slippageBps, minimumOut, actualOut) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint16, uint256, uint256));
                assertEq(slippageBps, 500);
                return (grossBudget, exactWethDebit, minimumOut, actualOut);
            }
        }
        fail("buyback event missing");
    }

    function _initialization(address rewardNft, address wethAddress, address vrfWrapper)
        private
        view
        returns (GovernanceInitialization memory initialization)
    {
        initialization = GovernanceInitialization({
            immutableConfiguration: ImmutableConfiguration({
                activationToken: address(token),
                rewardNFT: rewardNft,
                weth: wethAddress,
                vrfWrapper: vrfWrapper,
                uniswapV4PoolManager: address(manager),
                canonicalHook: address(hook),
                rewardNFTMaxSupply: 10_000,
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
                vrfRetryDelay: 1 hours,
                requestCallerReward: 0.01 ether,
                finalizationCallerReward: 0.01 ether,
                winnerShareBps: 5_000,
                nftShareBps: 3_000,
                treasuryShareBps: 1_000,
                buybackShareBps: 1_000
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
            buybackConfiguration: BuybackConfiguration({slippageBps: 500})
        });
    }

    function _facetCut(address facet, bytes4[] memory selectors)
        private
        pure
        returns (IDiamondCut.FacetCut memory cut)
    {
        cut = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _artifactSelectors(string memory artifactPath) private view returns (bytes4[] memory selectors) {
        // Paths are fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string[] memory signatures = vm.parseJsonKeys(vm.readFile(artifactPath), ".methodIdentifiers");
        selectors = new bytes4[](signatures.length);
        for (uint256 i; i < signatures.length; ++i) {
            selectors[i] = bytes4(keccak256(bytes(signatures[i])));
        }
    }

    function _deployArtifact(string memory artifact) private returns (address deployed) {
        bytes memory creationCode = vm.getCode(artifact);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "artifact deployment failed");
    }
}

contract AutomaticTicketBuybackTest is AutomaticTicketBuybackFixture {
    function setUp() public {
        _deployProtocol(true);
        _bootstrapPOL();
    }

    function test_PostPolTicketBatchExecutesOneBuybackAndPreservesAccounting() public {
        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        uint256 treasuryWethBefore = weth.balanceOf(treasury);
        uint128 lockedBefore = hook.lockedLiquidity();
        uint256 diamondWethBefore = weth.balanceOf(address(diamond));

        vm.recordLogs();
        _buyTickets(2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertOneCanonicalSwap(logs);
        _assertBilateralHookFees(logs);
        (uint256 grossBudget, uint256 exactWethDebit, uint256 minimumOut, uint256 actualOut) = _buybackEvent(logs);
        assertEq(grossBudget, 0.2 ether);
        assertEq(exactWethDebit, grossBudget);
        assertGe(actualOut, minimumOut);
        assertGe(token.balanceOf(treasury) - treasuryTokenBefore, actualOut);
        // Base ticket Treasury routing plus the hook's 10% share of the 50 bps WETH input-leg fee.
        assertEq(weth.balanceOf(treasury) - treasuryWethBefore, 0.8001 ether);
        assertEq(views.round(1).ticketCount, 77);
        assertEq(views.ticketBatchCount(1), 2);
        assertEq(weth.balanceOf(address(diamond)) - diamondWethBefore, 1 ether);
        assertGt(hook.lockedLiquidity(), lockedBefore);

        POLAccountingView memory accounting = pol.polAccounting();
        assertGe(token.balanceOf(address(hook)), accounting.pendingToken);
        assertGe(weth.balanceOf(address(hook)), accounting.pendingWeth);
    }

    function test_SlippageFailureRollsBackPurchaseAndCanRetryAfterGovernanceUpdate() public {
        governance.setBuybackConfiguration(BuybackConfiguration({slippageBps: 1}));
        uint256 ticketCountBefore = views.round(1).ticketCount;
        uint256 batchesBefore = views.ticketBatchCount(1);
        uint256 diamondWethBefore = weth.balanceOf(address(diamond));
        uint256 treasuryWethBefore = weth.balanceOf(treasury);
        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        uint128 lockedBefore = hook.lockedLiquidity();
        POLAccountingView memory accountingBefore = pol.polAccounting();

        vm.expectRevert();
        _buyTickets(25);

        assertEq(views.round(1).ticketCount, ticketCountBefore);
        assertEq(views.ticketBatchCount(1), batchesBefore);
        assertEq(weth.balanceOf(address(diamond)), diamondWethBefore);
        assertEq(weth.balanceOf(treasury), treasuryWethBefore);
        assertEq(token.balanceOf(treasury), treasuryTokenBefore);
        assertEq(hook.lockedLiquidity(), lockedBefore);
        assertEq(uint8(views.round(1).status), uint8(RoundStatus.Open));
        POLAccountingView memory accountingAfter = pol.polAccounting();
        assertEq(accountingAfter.pendingToken, accountingBefore.pendingToken);
        assertEq(accountingAfter.pendingWeth, accountingBefore.pendingWeth);

        governance.setBuybackConfiguration(BuybackConfiguration({slippageBps: 500}));
        _buyTickets(1);
        assertEq(views.round(1).ticketCount, ticketCountBefore + 1);
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
}

contract AutomaticTicketBuybackReverseOrderTest is AutomaticTicketBuybackFixture {
    function test_PostPolBuybackWorksWhenWethIsCurrency1() public {
        _deployProtocol(false);
        _bootstrapPOL();
        uint256 treasuryTokenBefore = token.balanceOf(treasury);

        vm.recordLogs();
        _buyTickets(1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertOneCanonicalSwap(logs);
        _assertBilateralHookFees(logs);
        (uint256 grossBudget,, uint256 minimumOut, uint256 actualOut) = _buybackEvent(logs);
        assertEq(grossBudget, 0.1 ether);
        assertGe(actualOut, minimumOut);
        assertGt(token.balanceOf(treasury), treasuryTokenBefore);
    }
}
