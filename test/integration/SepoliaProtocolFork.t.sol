// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVRFV2PlusWrapper} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusWrapper.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {DeployCrotto, CrottoDeploymentResult} from "../../script/DeployCrotto.s.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoBuilderFees} from "../../src/interfaces/ICrottoBuilderFees.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {ICrottoSwapFeeHook} from "../../src/interfaces/ICrottoSwapFeeHook.sol";
import {ICrottoView} from "../../src/interfaces/ICrottoView.sol";
import {IAutomaticTicketBuyback} from "../../src/interfaces/IAutomaticTicketBuyback.sol";
import {INFTVault} from "../../src/interfaces/INFTVault.sol";
import {IPOLInitialization} from "../../src/interfaces/IPOLInitialization.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {IActivationToken} from "../../src/interfaces/IActivationToken.sol";
import {
    BuilderTicketQuote,
    POLAccountingView,
    ProtocolAccountingView,
    RequestRecord,
    Round,
    RoundSettlement,
    RoundStatus
} from "../../src/types/CrottoTypes.sol";

interface IWeth9 is IERC20 {
    function deposit() external payable;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;

    function poolManager() external view returns (address);
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Ethereum Sepolia proof against deployed WETH, Chainlink VRF Wrapper,
/// Uniswap v4 PoolManager, Permit2, and Universal Router V2.
contract SepoliaProtocolForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant SEPOLIA_CHAIN_ID = 11_155_111;
    address private constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address private constant VRF_WRAPPER = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    address private constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address private constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address private constant TREASURY = 0x1111111111111111111111111111111111111111;
    address private constant GUARDIAN = 0x2222222222222222222222222222222222222222;
    address private constant PROPOSER = 0x3333333333333333333333333333333333333333;
    address private constant DEPLOYER = 0x4444444444444444444444444444444444444444;
    address private constant PLAYER = 0x5555555555555555555555555555555555555555;
    address private constant BUILDER = 0x6666666666666666666666666666666666666666;
    address private constant BUYBACK_CALLER = 0x7777777777777777777777777777777777777777;

    uint256 private constant TICKET_PRICE = 0.0001 ether;
    uint256 private constant OPERATIONS_FEE = 0.00012 ether;
    uint256 private constant TICKET_TARGET = 25;
    uint256 private constant ROUND_TICKET_VALUE = TICKET_PRICE * TICKET_TARGET;
    uint16 private constant BUILDER_FEE_BPS = 50;
    bytes1 private constant V4_SWAP = 0x10;
    bytes32 private constant BUYBACK_EVENT_SIGNATURE =
        keccak256("PendingBuybackExecuted(address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 private constant HOOK_FEE_EVENT_SIGNATURE =
        keccak256("SwapLegFeeAccrued(bytes32,address,bool,uint256,uint256,uint256,uint256)");

    ICrotto private lottery;
    ICrottoView private views;
    ICrottoBuilderFees private builders;
    ICrottoGovernance private governance;
    ICrottoRewards private rewards;
    INFTVault private vault;
    IPOLInitialization private pol;
    IAutomaticTicketBuyback private buyback;
    ICrottoSwapFeeHook private hook;
    IActivationToken private token;
    IWeth9 private weth;
    PoolKey private poolKey;
    PoolId private poolId;
    address private diamond;
    address private timelock;

    error MissingSepoliaRpc();

    function setUp() public {
        string memory rpc = vm.envOr("ETH_SEPOLIA", string(""));
        bool required = vm.envOr("CROTTO_REQUIRE_FORK_PROOF", false);
        if (bytes(rpc).length == 0) {
            if (required) revert MissingSepoliaRpc();
            vm.skip(true, "ETH_SEPOLIA is not configured");
            return;
        }

        uint256 forkBlock = vm.envOr("CROTTO_SEPOLIA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, SEPOLIA_CHAIN_ID);
        _assertDependencies();
        _deployCrotto();
    }

    function test_SepoliaFullProtocolLifecycle() public {
        vm.txGasPrice(5 gwei);
        vm.deal(PLAYER, 1 ether);
        vm.deal(BUYBACK_CALLER, 1 ether);

        _proveNativeTicketConversionAndBootstrap();
        _initializeCanonicalPOL();
        _proveGovernedOneSidedPOLAddition();
        _proveUniversalRouterSwaps();
        _activateRewardNft();
        _proveSuccessfulBuilderRoundAndBuyback();
        _proveExpiredBuilderRound();
        _assertProtocolSolvency();
    }

    function _assertDependencies() private view {
        assertGt(WETH.code.length, 0, "Sepolia WETH missing");
        assertGt(VRF_WRAPPER.code.length, 0, "Sepolia VRF wrapper missing");
        assertGt(POOL_MANAGER.code.length, 0, "Sepolia PoolManager missing");
        assertGt(UNIVERSAL_ROUTER.code.length, 0, "Sepolia Universal Router missing");
        assertGt(PERMIT2.code.length, 0, "Sepolia Permit2 missing");
        assertEq(IUniversalRouter(UNIVERSAL_ROUTER).poolManager(), POOL_MANAGER);
    }

    function _deployCrotto() private {
        vm.deal(DEPLOYER, 100 ether);
        vm.setEnv("DEPLOYER", vm.toString(DEPLOYER));
        vm.setEnv(
            "CROTTO_DEPLOYMENT_CONFIG",
            string.concat(vm.projectRoot(), "/script/config/sepolia-low-cost-rehearsal.json")
        );

        CrottoDeploymentResult memory deployed = new DeployCrotto().run();
        diamond = deployed.diamond;
        timelock = deployed.timelock;
        lottery = ICrotto(diamond);
        views = ICrottoView(diamond);
        builders = ICrottoBuilderFees(diamond);
        governance = ICrottoGovernance(diamond);
        rewards = ICrottoRewards(diamond);
        vault = INFTVault(diamond);
        pol = IPOLInitialization(diamond);
        buyback = IAutomaticTicketBuyback(diamond);
        hook = ICrottoSwapFeeHook(deployed.canonicalHook);
        token = IActivationToken(deployed.activationToken);
        weth = IWeth9(WETH);

        assertEq(governance.treasuryReceiver(), TREASURY);
        assertEq(governance.guardian(), GUARDIAN);
        assertEq(token.crottoDiamond(), diamond);
        assertEq(hook.crottoDiamond(), diamond);
    }

    function _proveNativeTicketConversionAndBootstrap() private {
        Round memory beforeRound = views.round(1);
        uint256 nativeBefore = PLAYER.balance;
        uint256 diamondWethBefore = weth.balanceOf(diamond);
        uint256 payment = (TICKET_PRICE + OPERATIONS_FEE) * TICKET_TARGET;

        vm.prank(PLAYER);
        lottery.buyTickets{value: payment}(TICKET_TARGET);

        Round memory closed = views.round(1);
        RoundSettlement memory settlement = views.roundSettlement(1);
        assertEq(uint256(beforeRound.status), uint256(RoundStatus.Open));
        assertEq(uint256(closed.status), uint256(RoundStatus.Closed));
        assertEq(closed.ticketCount, TICKET_TARGET);
        assertEq(nativeBefore - PLAYER.balance, payment);
        assertEq(weth.balanceOf(diamond) - diamondWethBefore, ROUND_TICKET_VALUE);
        assertEq(settlement.ticketEscrowWeth, ROUND_TICKET_VALUE);
        assertEq(settlement.bootstrapPolWeth, 0.001 ether);

        _requestAndFulfill(1, 17);
        lottery.finalizeLottery(1);
        assertEq(uint256(views.round(1).status), uint256(RoundStatus.Finalized));
        assertEq(pol.bootstrapPolWeth(), 0.001 ether);

        vm.prank(PLAYER);
        assertEq(lottery.claimPlayerRewards(1, PLAYER), 250 ether);
        assertEq(token.balanceOf(PLAYER), 250 ether);
    }

    function _requestAndFulfill(uint256 roundId, uint256 randomWord) private returns (uint256 requestId) {
        Round memory closed = views.round(roundId);
        uint256 quote = IVRFV2PlusWrapper(VRF_WRAPPER).calculateRequestPriceNative(250_000, 1);
        assertGt(quote, 0);
        assertLe(quote, closed.config.maxVrfCost);

        requestId = lottery.requestRandomness(roundId);
        RequestRecord memory record = views.requestRecord(requestId);
        assertTrue(record.known);
        assertEq(record.roundId, roundId);
        assertEq(record.attempt, 1);
        assertEq(views.round(roundId).requestAttempts, 1);

        vm.expectRevert();
        lottery.requestRandomness(roundId);

        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        vm.prank(VRF_WRAPPER);
        lottery.rawFulfillRandomWords(requestId, words);
        assertEq(uint256(views.round(roundId).status), uint256(RoundStatus.RandomReady));
    }

    function _initializeCanonicalPOL() private {
        assertTrue(pol.canInitializePOL());
        (, uint128 initialLiquidity) = pol.initializePOL();
        assertGt(initialLiquidity, 0);
        assertTrue(pol.polInitialized());
        assertTrue(token.bootstrapMintExecuted());
        assertEq(pol.bootstrapTokenMintAmount(), 10 ether);

        poolKey = hook.canonicalPoolKey();
        poolId = poolKey.toId();
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(pol.canonicalPoolId()));
        assertEq(poolKey.fee, 0, "canonical native LP fee");
        assertEq(address(poolKey.hooks), address(hook));
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _proveGovernedOneSidedPOLAddition() private {
        uint256 addedToken = 1 ether;
        vm.prank(TREASURY);
        token.approve(address(hook), addedToken);

        bytes memory callData = abi.encodeCall(ICrottoGovernance.addPOL, (TREASURY, addedToken, 0));
        bytes32 salt = keccak256("sepolia-governed-pol-addition");
        uint256 delay = TimelockController(payable(timelock)).getMinDelay();
        vm.prank(PROPOSER);
        TimelockController(payable(timelock)).schedule(diamond, 0, callData, bytes32(0), salt, delay);
        vm.warp(block.timestamp + delay);

        POLAccountingView memory beforeAccounting = pol.polAccounting();
        uint256 treasuryTokenBefore = token.balanceOf(TREASURY);
        TimelockController(payable(timelock)).execute(diamond, 0, callData, bytes32(0), salt);
        POLAccountingView memory afterAccounting = pol.polAccounting();
        assertEq(treasuryTokenBefore - token.balanceOf(TREASURY), addedToken);
        assertGt(afterAccounting.pendingToken, beforeAccounting.pendingToken);
        assertGe(afterAccounting.lockedLiquidity, beforeAccounting.lockedLiquidity);
    }

    function _proveUniversalRouterSwaps() private {
        vm.deal(PLAYER, PLAYER.balance + 0.01 ether);
        vm.prank(PLAYER);
        weth.deposit{value: 0.001 ether}();
        _approveUniversalRouter(PLAYER, address(token));
        _approveUniversalRouter(PLAYER, WETH);

        uint128 lockedBefore = hook.lockedLiquidity();
        uint256 playerTokenBefore = token.balanceOf(PLAYER);
        uint256 playerWethBefore = weth.balanceOf(PLAYER);
        uint256 managerTokenBefore = token.balanceOf(POOL_MANAGER);
        uint256 managerWethBefore = weth.balanceOf(POOL_MANAGER);

        _swapExactInput(PLAYER, WETH, 0.00001 ether);
        _swapExactInput(PLAYER, address(token), 0.05 ether);
        _swapExactOutput(PLAYER, WETH, 0.000001 ether, 0.1 ether);
        _swapExactOutput(PLAYER, address(token), 0.01 ether, 0.00001 ether);

        assertTrue(token.balanceOf(PLAYER) != playerTokenBefore);
        assertTrue(weth.balanceOf(PLAYER) != playerWethBefore);
        assertTrue(token.balanceOf(POOL_MANAGER) != managerTokenBefore);
        assertTrue(weth.balanceOf(POOL_MANAGER) != managerWethBefore);
        assertGt(hook.lockedLiquidity(), lockedBefore, "swap fees auto-compound POL");
        POLAccountingView memory accounting = pol.polAccounting();
        assertGe(token.balanceOf(address(hook)), accounting.pendingToken);
        assertGe(weth.balanceOf(address(hook)), accounting.pendingWeth);
    }

    function _approveUniversalRouter(address owner, address asset) private {
        vm.startPrank(owner);
        IERC20(asset).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(asset, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _swapExactInput(address trader, address assetIn, uint128 amountIn) private {
        bool zeroForOne = assetIn == Currency.unwrap(poolKey.currency0);
        Currency output = zeroForOne ? poolKey.currency1 : poolKey.currency0;
        uint256 maximumDebit = uint256(amountIn) + _ceilBps(amountIn, 50);
        IV4Router.ExactInputSingleParams memory params = IV4Router.ExactInputSingleParams({
            poolKey: poolKey, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: 0, hookData: ""
        });
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE_ALL)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(params);
        actionParams[1] = abi.encode(Currency.wrap(assetIn), maximumDebit);
        actionParams[2] = abi.encode(output, uint256(0));
        _executeRouter(trader, actions, actionParams);
    }

    function _swapExactOutput(address trader, address assetOut, uint128 amountOut, uint128 amountInMaximum) private {
        bool zeroForOne = assetOut == Currency.unwrap(poolKey.currency1);
        Currency input = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        IV4Router.ExactOutputSingleParams memory params = IV4Router.ExactOutputSingleParams({
            poolKey: poolKey,
            zeroForOne: zeroForOne,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            hookData: ""
        });
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_OUT_SINGLE)),
            bytes1(uint8(Actions.SETTLE_ALL)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(params);
        actionParams[1] = abi.encode(input, uint256(amountInMaximum));
        actionParams[2] = abi.encode(Currency.wrap(assetOut), uint256(amountOut));
        _executeRouter(trader, actions, actionParams);
    }

    function _executeRouter(address trader, bytes memory actions, bytes[] memory actionParams) private {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 1);
    }

    function _ceilBps(uint256 amount, uint256 bps) private pure returns (uint256) {
        return (amount * bps + 9_999) / 10_000;
    }

    function _activateRewardNft() private {
        vm.startPrank(PLAYER);
        token.approve(diamond, type(uint256).max);
        uint256 tokenId = vault.buyNewRewardNFT(PLAYER);
        (uint64 version,) = views.currentActivationConfiguration();
        rewards.activateNextTier(tokenId, version, 25 ether);
        vm.stopPrank();
        assertEq(rewards.totalActiveWeight(), 1);
    }

    function _proveSuccessfulBuilderRoundAndBuyback() private {
        vm.prank(PLAYER);
        builders.approveBuilder(BUILDER, BUILDER_FEE_BPS, true);
        BuilderTicketQuote memory quote =
            views.builderTicketQuote(2, TICKET_TARGET, PLAYER, BUILDER, BUILDER_FEE_BPS, true);
        assertEq(quote.ticketValueEth, ROUND_TICKET_VALUE);
        assertEq(quote.builderFeeEth, 0.0000125 ether);
        assertEq(quote.rewardBeneficiary, BUILDER);

        vm.prank(PLAYER);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(TICKET_TARGET, BUILDER, BUILDER_FEE_BPS, true);
        ProtocolAccountingView memory openAccounting = views.protocolAccounting();
        assertEq(openAccounting.ticketEscrowWeth, ROUND_TICKET_VALUE);
        assertEq(openAccounting.provisionalBuilderEth, quote.builderFeeEth);
        assertEq(builders.provisionalBuilderCredit(2, BUILDER), quote.builderFeeEth);

        _requestAndFulfill(2, 3);
        lottery.finalizeLottery(2);
        vm.prank(BUILDER);
        assertEq(builders.settleBuilderFees(2), quote.builderFeeEth);
        assertEq(builders.builderCredit(BUILDER), quote.builderFeeEth);
        assertEq(views.playerRewardEntitlement(2, PLAYER), 0);
        assertEq(views.playerRewardEntitlement(2, BUILDER), 250 ether);

        uint256 builderNativeBefore = BUILDER.balance;
        vm.prank(BUILDER);
        assertEq(builders.claimBuilderFees(BUILDER), quote.builderFeeEth);
        assertEq(BUILDER.balance - builderNativeBefore, quote.builderFeeEth);
        vm.prank(BUILDER);
        assertEq(lottery.claimPlayerRewards(2, BUILDER), 250 ether);

        uint256 pendingBefore = views.protocolAccounting().pendingBuybackWeth;
        uint256 diamondWethBefore = weth.balanceOf(diamond);
        uint256 callerWethBefore = weth.balanceOf(BUYBACK_CALLER);
        uint256 treasuryTokenBefore = token.balanceOf(TREASURY);
        uint128 lockedBefore = hook.lockedLiquidity();
        vm.recordLogs();
        vm.prank(BUYBACK_CALLER);
        (uint256 consumed, uint256 tokenOut) = buyback.executePendingBuyback();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(consumed, 0.0001 ether);
        assertGt(tokenOut, 0);
        assertEq(pendingBefore - views.protocolAccounting().pendingBuybackWeth, consumed);
        assertGt(diamondWethBefore - weth.balanceOf(diamond), 0);
        assertLe(diamondWethBefore - weth.balanceOf(diamond), consumed);
        assertEq(weth.balanceOf(BUYBACK_CALLER) - callerWethBefore, 0.0000001 ether);
        assertGt(token.balanceOf(TREASURY) - treasuryTokenBefore, tokenOut);
        assertGt(hook.lockedLiquidity(), lockedBefore);
        _assertBuybackEvent(logs, consumed, tokenOut);
        _assertBilateralHookFees(logs);

        (uint256 nftWeth,) = rewards.pendingNFTRewards(1);
        assertGt(nftWeth, 0, "post-POL active NFT earns finalized revenue");
    }

    function _proveExpiredBuilderRound() private {
        BuilderTicketQuote memory quote =
            views.builderTicketQuote(3, TICKET_TARGET, PLAYER, BUILDER, BUILDER_FEE_BPS, true);
        vm.prank(PLAYER);
        lottery.buyTicketsWithBuilder{value: quote.totalEth}(TICKET_TARGET, BUILDER, BUILDER_FEE_BPS, true);
        uint256 requestId = lottery.requestRandomness(3);
        Round memory pendingRound = views.round(3);
        vm.roll(uint256(pendingRound.latestRequestBlock) + pendingRound.config.vrfTimeoutBlocks + 1);

        uint256[] memory words = new uint256[](1);
        words[0] = 99;
        vm.prank(VRF_WRAPPER);
        lottery.rawFulfillRandomWords(requestId, words);
        assertEq(uint256(views.round(3).status), uint256(RoundStatus.VRFPending));

        lottery.expireLottery(3);
        ProtocolAccountingView memory expiredAccounting = views.protocolAccounting();
        assertEq(expiredAccounting.expiredTicketRefundWeth, ROUND_TICKET_VALUE);
        assertEq(expiredAccounting.expiredBuilderRefundEth, quote.builderFeeEth);
        assertEq(builders.provisionalBuilderCredit(3, BUILDER), 0);
        assertEq(views.round(3).totalPlayerRewardLiability, 0);
        vm.prank(BUILDER);
        vm.expectRevert();
        lottery.claimPlayerRewards(3, BUILDER);

        uint256 playerWethBefore = weth.balanceOf(PLAYER);
        uint256 playerNativeBefore = PLAYER.balance;
        vm.prank(PLAYER);
        (uint256 ticketRefund, uint256 builderRefund) = lottery.claimExpiredRoundRefund(3, PLAYER, PLAYER);
        assertEq(ticketRefund, ROUND_TICKET_VALUE);
        assertEq(builderRefund, quote.builderFeeEth);
        assertEq(weth.balanceOf(PLAYER) - playerWethBefore, ROUND_TICKET_VALUE);
        assertEq(PLAYER.balance - playerNativeBefore, quote.builderFeeEth);
    }

    function _assertProtocolSolvency() private view {
        ProtocolAccountingView memory accounting = views.protocolAccounting();
        uint256 requiredWeth = accounting.winnerPoolWethLiability + accounting.rewardNftWethLiability
            + accounting.bootstrapPolWeth + accounting.ticketEscrowWeth + accounting.expiredTicketRefundWeth
            + accounting.pendingBuybackWeth;
        uint256 requiredNative =
            accounting.operationsReserveEth + accounting.callerCreditsEth + builders.totalBuilderFeeLiability();
        assertGe(weth.balanceOf(diamond), requiredWeth);
        assertGe(diamond.balance, requiredNative);
        assertEq(accounting.ticketEscrowWeth, 0);
        assertEq(accounting.expiredTicketRefundWeth, 0);
        assertEq(accounting.expiredBuilderRefundEth, 0);
        assertEq(accounting.provisionalBuilderEth, 0);
    }

    function _assertBuybackEvent(Vm.Log[] memory logs, uint256 expectedConsumed, uint256 expectedOut) private {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != diamond || logs[i].topics.length == 0 || logs[i].topics[0] != BUYBACK_EVENT_SIGNATURE
            ) {
                continue;
            }
            assertEq(address(uint160(uint256(logs[i].topics[1]))), BUYBACK_CALLER);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), TREASURY);
            assertEq(uint256(logs[i].topics[3]), 1);
            (
                uint256 consumed,
                uint256 tip,
                uint256 specifiedWethIn,
                uint256 inputHookFee,
                uint256 exactWethDebit,
                uint256 actualOut
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(consumed, expectedConsumed);
            assertEq(tip, 0.0000001 ether);
            assertEq(specifiedWethIn + tip, expectedConsumed);
            assertEq(exactWethDebit, specifiedWethIn);
            assertEq(inputHookFee, _ceilBps(specifiedWethIn, 50));
            assertEq(actualOut, expectedOut);
            return;
        }
        fail("buyback event missing");
    }

    function _assertBilateralHookFees(Vm.Log[] memory logs) private view {
        bool sawToken;
        bool sawWeth;
        uint256 feeEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics.length != 0
                    && logs[i].topics[0] == HOOK_FEE_EVENT_SIGNATURE
            ) {
                address asset = address(uint160(uint256(logs[i].topics[2])));
                if (asset == address(token)) sawToken = true;
                if (asset == WETH) sawWeth = true;
                ++feeEvents;
            }
        }
        assertEq(feeEvents, 2);
        assertTrue(sawToken && sawWeth);
    }
}
