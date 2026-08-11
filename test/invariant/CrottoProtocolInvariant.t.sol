// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {NFTVaultFacet} from "../../src/diamond/facets/NFTVaultFacet.sol";
import {OperationsFacet} from "../../src/diamond/facets/OperationsFacet.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IERC173} from "../../src/interfaces/diamond/IERC173.sol";
import {ICrotto} from "../../src/interfaces/ICrotto.sol";
import {ICrottoBuilderFees} from "../../src/interfaces/ICrottoBuilderFees.sol";
import {ICrottoGovernance} from "../../src/interfaces/ICrottoGovernance.sol";
import {ICrottoRewards} from "../../src/interfaces/ICrottoRewards.sol";
import {ICrottoSwapFeeHook} from "../../src/interfaces/ICrottoSwapFeeHook.sol";
import {INFTVault} from "../../src/interfaces/INFTVault.sol";
import {IPOLInitialization} from "../../src/interfaces/IPOLInitialization.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {LibRewardAccounting} from "../../src/libraries/LibRewardAccounting.sol";
import {LibBuybackStorage} from "../../src/libraries/storage/LibBuybackStorage.sol";
import {LibBuilderFeesStorage} from "../../src/libraries/storage/LibBuilderFeesStorage.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "../../src/libraries/storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "../../src/libraries/storage/LibRewardsStorage.sol";
import {LibRoundSettlementStorage} from "../../src/libraries/storage/LibRoundSettlementStorage.sol";
import {LibTreasuryStorage} from "../../src/libraries/storage/LibTreasuryStorage.sol";
import {LibVaultStorage} from "../../src/libraries/storage/LibVaultStorage.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";
import {
    ActivationConfiguration,
    BuybackConfiguration,
    HookConfiguration,
    NFTRewardPosition,
    Round,
    RoundConfiguration,
    RoundStatus,
    VaultAccountingView
} from "../../src/types/CrottoTypes.sol";
import {AutomaticTicketBuybackFixture, BuybackVrfWrapperProbe} from "../liquidity/AutomaticTicketBuyback.t.sol";
import {IPoolSwapRouter} from "../liquidity/CrottoSwapFeeHook.t.sol";

struct InvariantAccountingView {
    uint256 winnerWeth;
    uint256 playerToken;
    uint256 rewardWeth;
    uint256 rewardToken;
    uint256 vaultToken;
    uint256 bootstrapWeth;
    uint256 operationsEth;
    uint256 callerCreditsEth;
    uint256 builderCreditsEth;
    uint256 ticketEscrowWeth;
    uint256 expiredTicketRefundWeth;
    uint256 pendingBuybackWeth;
    uint256 lotteryNftWeth;
}

interface IInvariantProbe {
    function protocolAccountingProbe() external view returns (InvariantAccountingView memory);

    function buybackState()
        external
        view
        returns (uint256 reserved0, uint256 reserved1, uint256 reserved2, bytes32 active);

    function activationState() external view returns (uint256 version, ActivationConfiguration memory configuration);

    function roundConfiguration() external view returns (RoundConfiguration memory);
}

contract InvariantProbeFacet {
    function protocolAccountingProbe() external view returns (InvariantAccountingView memory accounting) {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        LibRewardsStorage.Layout storage rewards = LibRewardsStorage.layout();
        LibTreasuryStorage.Layout storage treasury = LibTreasuryStorage.layout();
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        accounting = InvariantAccountingView({
            winnerWeth: lottery.totalWinnerPoolWethLiability,
            playerToken: lottery.totalPlayerTokenLiability,
            rewardWeth: LibRewardAccounting.outstanding(rewards.wethBook),
            rewardToken: LibRewardAccounting.outstanding(rewards.tokenBook),
            vaultToken: LibVaultStorage.layout().tokenBacking,
            bootstrapWeth: LibPOLStorage.layout().bootstrapWeth,
            operationsEth: treasury.operationsReserveEth,
            callerCreditsEth: treasury.totalCallerCreditsEth,
            builderCreditsEth: LibBuilderFeesStorage.layout().totalNativeEthLiability,
            ticketEscrowWeth: settlements.activeTicketEscrowWeth,
            expiredTicketRefundWeth: settlements.expiredTicketRefundWeth,
            pendingBuybackWeth: settlements.pendingBuybackWeth,
            lotteryNftWeth: settlements.lotteryNftWethLiability
        });
    }

    function buybackState()
        external
        view
        returns (uint256 reserved0, uint256 reserved1, uint256 reserved2, bytes32 active)
    {
        LibBuybackStorage.Layout storage state = LibBuybackStorage.layout();
        return (
            state.__reservedLegacyWethReserve,
            state.__reservedLegacyTotalTicketsSold,
            state.__reservedLegacyTicketsAtLastBuyback,
            state.activeExecutionHash
        );
    }

    function activationState() external view returns (uint256 version, ActivationConfiguration memory configuration) {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        return (governance.activationConfigurationVersion, governance.activationConfiguration);
    }

    function roundConfiguration() external view returns (RoundConfiguration memory) {
        return LibGovernanceStorage.layout().roundConfiguration;
    }
}

struct InvariantProtocolRefs {
    address diamond;
    address token;
    address rewardNft;
    address weth;
    address hook;
    address wrapper;
    address manager;
    address swapRouter;
    address initialTreasury;
    address guardian;
}

contract CrottoProtocolHandler is Test {
    uint256 private constant BPS = 10_000;
    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant BUYBACK_EVENT = keccak256(
        "AutomaticTicketBuybackExecuted(uint256,address,address,uint256,uint256,uint256,uint256,uint16,uint256,uint256)"
    );

    ICrotto public immutable lottery;
    ICrottoGovernance public immutable governance;
    ICrottoBuilderFees public immutable builders;
    ICrottoRewards public immutable rewards;
    INFTVault public immutable vault;
    IPOLInitialization public immutable pol;
    IInvariantProbe public immutable probe;
    ActivationToken public immutable token;
    RewardNFT public immutable rewardNft;
    IERC20 public immutable weth;
    ICrottoSwapFeeHook public immutable hook;
    BuybackVrfWrapperProbe public immutable wrapper;
    IPoolSwapRouter public immutable swapRouter;
    address public immutable manager;
    address public immutable diamond;
    address public immutable initialTreasury;
    address public immutable guardian;
    PoolKey private canonicalKey;

    address[4] public actors;
    address[2] public alternateTreasuries;
    uint256[] public requestIds;
    mapping(uint256 roundId => uint256 word) public acceptedWords;
    mapping(uint256 roundId => bool recorded) public acceptedWordRecorded;
    mapping(uint256 roundId => address winner) public finalizedWinners;
    mapping(uint256 roundId => uint256 ticket) public finalizedTickets;
    mapping(uint256 roundId => uint256 count) public winnerClaimCount;
    mapping(uint256 roundId => mapping(address player => uint256 count)) public playerClaimCount;
    mapping(address builder => uint256 credit) public modeledBuilderCredits;
    mapping(uint256 roundId => mapping(address builder => uint256 credit)) public modeledProvisionalBuilderCredits;
    mapping(uint256 roundId => mapping(address buyer => uint256 refund)) public modeledBuilderRefunds;
    uint256 public modeledBuilderLiability;

    uint256 public playerRewardsMinted;
    uint256 public activationTokensBurned;
    uint256 public bootstrapMintCount;
    uint256 public bootstrapMintAmount;
    uint128 public lastLockedLiquidity;
    bool public liquidityDecreased;
    bool public purchaseRollbackViolation;
    bool public operationsRoutingViolation;
    bool public buybackBudgetViolation;
    bool public randomnessChanged;
    bool public winnerChanged;

    constructor(InvariantProtocolRefs memory refs, PoolKey memory key) {
        diamond = refs.diamond;
        lottery = ICrotto(refs.diamond);
        governance = ICrottoGovernance(refs.diamond);
        builders = ICrottoBuilderFees(refs.diamond);
        rewards = ICrottoRewards(refs.diamond);
        vault = INFTVault(refs.diamond);
        pol = IPOLInitialization(refs.diamond);
        probe = IInvariantProbe(refs.diamond);
        token = ActivationToken(refs.token);
        rewardNft = RewardNFT(refs.rewardNft);
        weth = IERC20(refs.weth);
        hook = ICrottoSwapFeeHook(refs.hook);
        wrapper = BuybackVrfWrapperProbe(refs.wrapper);
        manager = refs.manager;
        swapRouter = IPoolSwapRouter(refs.swapRouter);
        initialTreasury = refs.initialTreasury;
        guardian = refs.guardian;
        canonicalKey = key;
        alternateTreasuries = [address(0x7111), address(0x7222)];
    }

    function seedActors() external {
        require(actors[0] == address(0), "actors seeded");
        for (uint256 i; i < actors.length; ++i) {
            address actor = address(uint160(0xA110 + i));
            actors[i] = actor;
            vm.deal(actor, 1_000 ether);
            vm.prank(initialTreasury);
            assertTrue(token.transfer(actor, 250_000 ether));
            vm.prank(actor);
            IWETH9(address(weth)).deposit{value: 100 ether}();
            vm.startPrank(actor);
            token.approve(diamond, type(uint256).max);
            token.approve(address(hook), type(uint256).max);
            token.approve(address(swapRouter), type(uint256).max);
            weth.approve(address(hook), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        lastLockedLiquidity = hook.lockedLiquidity();
    }

    function buyTickets(uint256 actorSeed, uint256 quantitySeed) external {
        uint256 roundId = _currentRoundId();
        Round memory current = _round(roundId);
        if (current.status != RoundStatus.Open) return;
        if (current.ticketCount >= current.config.ticketTarget) return;
        uint256 remaining = current.config.ticketTarget - current.ticketCount;
        uint256 quantity = bound(quantitySeed, 1, remaining);
        address actor = _actor(actorSeed);
        uint256 payment = (current.config.ticketPrice + current.config.ticketOperationsFee) * quantity;
        if (actor.balance < payment) return;

        InvariantAccountingView memory accountingBefore = probe.protocolAccountingProbe();
        uint256 nativeBefore = diamond.balance;
        bytes32 beforeDigest = _purchaseDigest(roundId);
        vm.recordLogs();
        vm.prank(actor);
        (bool success,) = diamond.call{value: payment}(abi.encodeCall(ICrotto.buyTickets, (quantity)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!success) {
            if (_purchaseDigest(roundId) != beforeDigest) purchaseRollbackViolation = true;
            return;
        }

        uint256 ticketValue = current.config.ticketPrice * quantity;
        uint256 operationsFee = current.config.ticketOperationsFee * quantity;
        uint256 reserveContribution =
            _reserveContribution(accountingBefore.operationsEth, current.config.operationsReserveCap, operationsFee);
        InvariantAccountingView memory accountingAfter = probe.protocolAccountingProbe();
        if (
            accountingAfter.operationsEth != accountingBefore.operationsEth + reserveContribution
                || accountingAfter.ticketEscrowWeth != accountingBefore.ticketEscrowWeth + ticketValue
                || diamond.balance != nativeBefore + reserveContribution || _containsCanonicalSwap(logs)
        ) operationsRoutingViolation = true;
        _observeLiquidity();
    }

    function setBuilderApproval(uint256 playerSeed, uint256 builderSeed, uint256 feeSeed, bool redirect) external {
        address buyer = _actor(playerSeed);
        address builder = _actor(builderSeed);
        uint16 maximumFeeBps = SafeCast.toUint16(bound(feeSeed, 0, 50));
        if (maximumFeeBps == 0 && !redirect) redirect = true;
        vm.prank(buyer);
        try builders.approveBuilder(builder, maximumFeeBps, redirect) {} catch {}
    }

    function revokeBuilder(uint256 playerSeed, uint256 builderSeed) external {
        vm.prank(_actor(playerSeed));
        try builders.revokeBuilder(_actor(builderSeed)) {} catch {}
    }

    function buyTicketsWithBuilder(
        uint256 playerSeed,
        uint256 builderSeed,
        uint256 quantitySeed,
        uint256 feeSeed,
        bool redirect
    ) external {
        uint256 roundId = _currentRoundId();
        Round memory current = _round(roundId);
        if (current.status != RoundStatus.Open || current.ticketCount >= current.config.ticketTarget) return;
        address buyer = _actor(playerSeed);
        address builder = _actor(builderSeed);
        uint16 approved = builders.builderApproval(buyer, builder).maximumFeeBps;
        uint16 feeBps = SafeCast.toUint16(bound(feeSeed, 0, approved));
        uint256 quantity = bound(quantitySeed, 1, current.config.ticketTarget - current.ticketCount);
        uint256 ticketValue = current.config.ticketPrice * quantity;
        uint256 builderFee = Math.mulDiv(ticketValue, feeBps, BPS);
        uint256 payment = ticketValue + current.config.ticketOperationsFee * quantity + builderFee;
        if (buyer.balance < payment) return;

        InvariantAccountingView memory accountingBefore = probe.protocolAccountingProbe();
        uint256 nativeBefore = diamond.balance;
        bytes32 beforeDigest = _purchaseDigest(roundId);
        vm.prank(buyer);
        (bool success,) = diamond.call{value: payment}(
            abi.encodeCall(ICrotto.buyTicketsWithBuilder, (quantity, builder, feeBps, redirect))
        );
        if (!success) {
            if (_purchaseDigest(roundId) != beforeDigest) purchaseRollbackViolation = true;
            return;
        }
        modeledProvisionalBuilderCredits[roundId][builder] += builderFee;
        modeledBuilderRefunds[roundId][buyer] += builderFee;
        modeledBuilderLiability += builderFee;
        uint256 operationsFee = current.config.ticketOperationsFee * quantity;
        uint256 reserveContribution =
            _reserveContribution(accountingBefore.operationsEth, current.config.operationsReserveCap, operationsFee);
        InvariantAccountingView memory accountingAfter = probe.protocolAccountingProbe();
        if (
            accountingAfter.operationsEth != accountingBefore.operationsEth + reserveContribution
                || accountingAfter.ticketEscrowWeth != accountingBefore.ticketEscrowWeth + ticketValue
                || diamond.balance != nativeBefore + reserveContribution + builderFee
        ) operationsRoutingViolation = true;
        _observeLiquidity();
    }

    function fundOperationsReserve(uint256 actorSeed, uint256 amountSeed) external {
        uint256 roundId = _currentRoundId();
        if (roundId == 0) return;
        Round memory current = _round(roundId);
        InvariantAccountingView memory accountingBefore = probe.protocolAccountingProbe();
        uint256 headroom = accountingBefore.operationsEth < current.config.operationsReserveCap
            ? current.config.operationsReserveCap - accountingBefore.operationsEth
            : 0;
        uint256 amount = bound(amountSeed, 1, uint256(current.config.operationsReserveCap) + 1);
        address actor = _actor(actorSeed);
        uint256 nativeBefore = diamond.balance;

        vm.prank(actor);
        (bool success,) = diamond.call{value: amount}(abi.encodeCall(ICrotto.fundOperationsReserve, ()));
        InvariantAccountingView memory accountingAfter = probe.protocolAccountingProbe();
        if (success) {
            if (
                amount > headroom || accountingAfter.operationsEth != accountingBefore.operationsEth + amount
                    || diamond.balance != nativeBefore + amount
            ) operationsRoutingViolation = true;
        } else if (accountingAfter.operationsEth != accountingBefore.operationsEth || diamond.balance != nativeBefore) {
            operationsRoutingViolation = true;
        }
    }

    function claimBuilderFees(uint256 builderSeed) external {
        address builder = _actor(builderSeed);
        uint256 expected = modeledBuilderCredits[builder];
        if (expected == 0) return;
        vm.prank(builder);
        try builders.claimBuilderFees(builder) returns (uint256 amount) {
            if (amount != expected) purchaseRollbackViolation = true;
            modeledBuilderCredits[builder] = 0;
            modeledBuilderLiability -= amount;
        } catch {}
    }

    function settleBuilderFees(uint256 roundSeed, uint256 builderSeed) external {
        uint256 roundId = _boundedRound(roundSeed);
        if (roundId == 0) return;
        address builder = _actor(builderSeed);
        uint256 expected = modeledProvisionalBuilderCredits[roundId][builder];
        if (expected == 0) return;
        vm.prank(builder);
        try builders.settleBuilderFees(roundId) returns (uint256 amount) {
            if (amount != expected) purchaseRollbackViolation = true;
            modeledProvisionalBuilderCredits[roundId][builder] = 0;
            modeledBuilderCredits[builder] += amount;
        } catch {}
    }

    function claimExpiredRoundRefund(uint256 roundSeed, uint256 actorSeed) external {
        uint256 roundId = _boundedRound(roundSeed);
        if (roundId == 0 || _round(roundId).status != RoundStatus.Expired) return;
        address actor = _actor(actorSeed);
        uint256 expectedBuilderRefund = modeledBuilderRefunds[roundId][actor];
        vm.prank(actor);
        try lottery.claimExpiredRoundRefund(roundId, actor, actor) returns (uint256, uint256 builderRefund) {
            if (builderRefund != expectedBuilderRefund) purchaseRollbackViolation = true;
            modeledBuilderRefunds[roundId][actor] = 0;
            modeledBuilderLiability -= builderRefund;
        } catch {}
    }

    function initializePOL(uint256) external {
        if (!pol.canInitializePOL()) return;
        uint256 supplyBefore = token.totalSupply();
        uint256 expectedMint = pol.bootstrapTokenMintAmount();
        try pol.initializePOL() {
            ++bootstrapMintCount;
            bootstrapMintAmount += token.totalSupply() - supplyBefore;
            if (token.totalSupply() - supplyBefore != expectedMint) buybackBudgetViolation = true;
            _observeLiquidity();
        } catch {}
    }

    function requestRandomness(uint256 actorSeed) external {
        uint256 roundId = _currentRoundId();
        if (_round(roundId).status != RoundStatus.Closed) return;
        vm.prank(_actor(actorSeed));
        try lottery.requestRandomness(roundId) returns (uint256 requestId) {
            requestIds.push(requestId);
        } catch {}
    }

    function expireLottery(uint256 actorSeed) external {
        uint256 roundId = _currentRoundId();
        Round memory current = _round(roundId);
        if (current.status != RoundStatus.Closed && current.status != RoundStatus.VRFPending) return;
        vm.roll(block.number + current.config.vrfTimeoutBlocks + 1);
        vm.prank(_actor(actorSeed));
        try lottery.expireLottery(roundId) {
            for (uint256 i; i < actors.length; ++i) {
                modeledProvisionalBuilderCredits[roundId][actors[i]] = 0;
            }
        } catch {}
    }

    function fulfillRandomness(uint256 requestSeed, uint256 randomWord) external {
        if (requestIds.length == 0) return;
        uint256 requestId = requestIds[requestSeed % requestIds.length];
        uint256 roundId = _requestRound(requestId);
        if (roundId == 0) return;
        Round memory beforeRound = _round(roundId);
        try wrapper.fulfill(requestId, randomWord) {
            Round memory afterRound = _round(roundId);
            uint256 stored = acceptedWords[roundId];
            if (afterRound.status == RoundStatus.RandomReady) {
                if (!acceptedWordRecorded[roundId]) {
                    acceptedWords[roundId] = afterRound.acceptedRandomWord;
                    acceptedWordRecorded[roundId] = true;
                } else if (stored != afterRound.acceptedRandomWord) {
                    randomnessChanged = true;
                }
            } else if (acceptedWordRecorded[roundId] && beforeRound.acceptedRandomWord != afterRound.acceptedRandomWord)
            {
                randomnessChanged = true;
            }
        } catch {}
    }

    function finalizeLottery(uint256 actorSeed) external {
        uint256 roundId = _currentRoundId();
        if (_round(roundId).status != RoundStatus.RandomReady) return;
        vm.prank(_actor(actorSeed));
        try lottery.finalizeLottery(roundId) {
            Round memory finalized = _round(roundId);
            address storedWinner = finalizedWinners[roundId];
            if (storedWinner == address(0)) {
                finalizedWinners[roundId] = finalized.winner;
                finalizedTickets[roundId] = finalized.winningTicket + 1;
            } else if (storedWinner != finalized.winner || finalizedTickets[roundId] != finalized.winningTicket + 1) {
                winnerChanged = true;
            }
        } catch {}
    }

    function claimWinnings(uint256 roundSeed) external {
        uint256 roundId = _boundedRound(roundSeed);
        if (roundId == 0) return;
        Round memory finalized = _round(roundId);
        if (finalized.status != RoundStatus.Finalized || finalized.winner == address(0)) return;
        vm.prank(finalized.winner);
        try lottery.claimWinnings(roundId, finalized.winner) returns (uint256) {
            ++winnerClaimCount[roundId];
        } catch {}
    }

    function claimPlayerRewards(uint256 roundSeed, uint256 actorSeed) external {
        uint256 roundId = _boundedRound(roundSeed);
        if (roundId == 0) return;
        address actor = _actor(actorSeed);
        uint256 entitlement = _rewardTickets(roundId, actor) * _round(roundId).config.playerRewardRate;
        if (entitlement == 0) return;
        uint256 supplyBefore = token.totalSupply();
        vm.prank(actor);
        try lottery.claimPlayerRewards(roundId, actor) returns (uint256 amount) {
            ++playerClaimCount[roundId][actor];
            playerRewardsMinted += amount;
            if (token.totalSupply() - supplyBefore != amount) purchaseRollbackViolation = true;
        } catch {}
    }

    function claimCallerRewards(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try lottery.claimCallerRewards(actor) returns (uint256) {} catch {}
    }

    function buyNewRewardNFT(uint256 actorSeed) external {
        if (rewardNft.mintedSupply() >= rewardNft.maxSupply()) return;
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try vault.buyNewRewardNFT(actor) returns (uint256) {} catch {}
    }

    function buyInventoryRewardNFT(uint256 actorSeed, uint256 tokenSeed) external {
        uint256 minted = rewardNft.mintedSupply();
        if (minted != rewardNft.maxSupply() || vault.vaultInventory() == 0) return;
        uint256 tokenId = bound(tokenSeed, 1, minted);
        if (!vault.isVaultInventory(tokenId)) return;
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try vault.buyInventoryRewardNFT(tokenId, actor) {} catch {}
    }

    function redeemRewardNFT(uint256 tokenSeed) external {
        uint256 tokenId = _boundedTokenId(tokenSeed);
        if (tokenId == 0) return;
        address owner = rewardNft.ownerOf(tokenId);
        if (!_isActor(owner)) return;
        vm.prank(owner);
        rewardNft.approve(diamond, tokenId);
        vm.prank(owner);
        try vault.redeemRewardNFT(tokenId, owner) {} catch {}
    }

    function activateRewardNFT(uint256 tokenSeed) external {
        uint256 tokenId = _boundedTokenId(tokenSeed);
        if (tokenId == 0) return;
        address owner = rewardNft.ownerOf(tokenId);
        if (!_isActor(owner)) return;
        NFTRewardPosition memory position = rewards.nftRewardPosition(tokenId);
        if (position.tier == 3) return;
        (uint256 version, ActivationConfiguration memory configuration) = probe.activationState();
        if (version > type(uint64).max) return;
        uint256 supplyBefore = token.totalSupply();
        vm.prank(owner);
        try rewards.activateNextTier(tokenId, uint64(version), configuration.costs[position.tier]) {
            activationTokensBurned += supplyBefore - token.totalSupply();
        } catch {}
    }

    function transferRewardNFT(uint256 tokenSeed, uint256 receiverSeed) external {
        uint256 tokenId = _boundedTokenId(tokenSeed);
        if (tokenId == 0) return;
        address owner = rewardNft.ownerOf(tokenId);
        if (!_isActor(owner)) return;
        address receiver = _actor(receiverSeed);
        if (receiver == owner) return;
        vm.prank(owner);
        try rewardNft.transferFrom(owner, receiver, tokenId) {} catch {}
    }

    function donateRewardNFT(uint256 tokenSeed) external {
        uint256 tokenId = _boundedTokenId(tokenSeed);
        if (tokenId == 0) return;
        address owner = rewardNft.ownerOf(tokenId);
        if (!_isActor(owner)) return;
        vm.prank(owner);
        try rewardNft.transferFrom(owner, diamond, tokenId) {} catch {}
    }

    function claimNFTReward(uint256 tokenSeed, uint256 assetSeed) external {
        uint256 tokenId = _boundedTokenId(tokenSeed);
        if (tokenId == 0) return;
        address owner = rewardNft.ownerOf(tokenId);
        if (!_isActor(owner)) return;
        vm.prank(owner);
        if (assetSeed % 2 == 0) {
            try rewards.claimNFTWethReward(tokenId, owner) returns (uint256) {} catch {}
        } else {
            try rewards.claimNFTTokenReward(tokenId, owner) returns (uint256) {} catch {}
        }
    }

    function donatePOL(uint256 actorSeed, uint256 tokenSeed, uint256 wethSeed) external {
        if (!pol.polInitialized()) return;
        address actor = _actor(actorSeed);
        uint256 tokenMaximum = _min(token.balanceOf(actor), 1_000 ether);
        uint256 wethMaximum = _min(weth.balanceOf(actor), 0.1 ether);
        uint256 tokenAmount = tokenMaximum == 0 ? 0 : bound(tokenSeed, 0, tokenMaximum);
        uint256 wethAmount = wethMaximum == 0 ? 0 : bound(wethSeed, 0, wethMaximum);
        if (tokenAmount == 0 && wethAmount == 0) return;
        uint256 tokenBefore = token.balanceOf(actor);
        uint256 wethBefore = weth.balanceOf(actor);
        vm.prank(actor);
        try hook.donatePOL(tokenAmount, wethAmount) returns (uint128) {
            if (tokenBefore - token.balanceOf(actor) != tokenAmount) purchaseRollbackViolation = true;
            if (wethBefore - weth.balanceOf(actor) != wethAmount) purchaseRollbackViolation = true;
            _observeLiquidity();
        } catch {}
    }

    function compoundPOL(uint256) external {
        if (!pol.polInitialized()) return;
        try hook.compoundPOL() returns (uint128) {
            _observeLiquidity();
        } catch {}
    }

    function swap(uint256 actorSeed, uint256 directionSeed, uint256 exactSeed, uint256 amountSeed) external {
        if (!pol.polInitialized()) return;
        address actor = _actor(actorSeed);
        bool tokenToWeth = directionSeed % 2 == 0;
        bool exactInput = exactSeed % 2 == 0;
        uint256 ceiling = tokenToWeth ? 100 ether : 0.01 ether;
        uint256 amount = bound(amountSeed, 1, ceiling);
        bool tokenIsCurrency0 = Currency.unwrap(canonicalKey.currency0) == address(token);
        bool zeroForOne = tokenToWeth == tokenIsCurrency0;
        vm.prank(actor);
        try swapRouter.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInput ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            IPoolSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {
            _observeLiquidity();
        } catch {}
    }

    function setBuybackConfiguration(uint256 tipSeed, uint256 chunkSeed) external {
        governance.setBuybackConfiguration(
            BuybackConfiguration({
                callerTipBps: uint16(bound(tipSeed, 0, 100)), maximumWethChunk: uint128(bound(chunkSeed, 1, 0.5 ether))
            })
        );
    }

    function setHookConfiguration(uint256 inputSeed, uint256 outputSeed, uint256 polSeed, uint256 nftSeed) external {
        uint16 inputFee = uint16(bound(inputSeed, 0, 100));
        uint16 outputFee = uint16(bound(outputSeed, 0, 100 - inputFee));
        uint16 polShare = uint16(bound(polSeed, 0, BPS));
        uint16 nftShare = uint16(bound(nftSeed, 0, BPS - polShare));
        governance.setHookConfiguration(
            HookConfiguration({
                inputFeeBps: inputFee,
                outputFeeBps: outputFee,
                polShareBps: polShare,
                nftShareBps: nftShare,
                treasuryShareBps: uint16(BPS - polShare - nftShare)
            })
        );
    }

    function setRoundRewardRate(uint256 rateSeed) external {
        RoundConfiguration memory configuration = probe.roundConfiguration();
        configuration.playerRewardRate = bound(rateSeed, 1, 1_000 ether);
        governance.setRoundConfiguration(configuration);
    }

    function setActivationConfiguration(uint256 costSeed, uint256 weightSeed) external {
        (, ActivationConfiguration memory configuration) = probe.activationState();
        uint256 firstCost = bound(costSeed, 1, 100 ether);
        uint256 firstWeight = bound(weightSeed, 1, 100);
        configuration.costs = [firstCost, firstCost + 1, firstCost + 2];
        configuration.destinationWeights = [firstWeight, firstWeight + 1, firstWeight + 2];
        governance.setActivationConfiguration(configuration);
    }

    function setTreasuryReceiver(uint256 receiverSeed) external {
        governance.setTreasuryReceiver(alternateTreasuries[receiverSeed % alternateTreasuries.length]);
    }

    function pauseActions(uint256 flagsSeed) external {
        uint256 flags = bound(flagsSeed, 1, 7);
        vm.prank(guardian);
        try governance.pauseActions(flags) {} catch {}
    }

    function unpauseActions(uint256 flagsSeed) external {
        governance.unpauseActions(bound(flagsSeed, 1, 7));
    }

    function _checkBuybackLogs(Vm.Log[] memory logs, uint256 roundId, address actor, uint256 expectedGross) private {
        uint256 buybacks;
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == manager && logs[i].topics[0] == SWAP_EVENT) ++swaps;
            if (logs[i].emitter != diamond || logs[i].topics[0] != BUYBACK_EVENT) continue;
            ++buybacks;
            if (uint256(logs[i].topics[1]) != roundId) buybackBudgetViolation = true;
            if (address(uint160(uint256(logs[i].topics[2]))) != actor) buybackBudgetViolation = true;
            (uint256 grossBudget, uint256 specifiedInput,, uint256 exactDebit,,, uint256 actualOut) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint16, uint256, uint256));
            if (
                grossBudget != expectedGross || specifiedInput != expectedGross || exactDebit != expectedGross
                    || actualOut == 0
            ) buybackBudgetViolation = true;
        }
        if (buybacks != 1 || swaps != 1) buybackBudgetViolation = true;
    }

    function _purchaseDigest(uint256 roundId) private view returns (bytes32) {
        InvariantAccountingView memory accounting = probe.protocolAccountingProbe();
        Round memory current = _round(roundId);
        (,,, bytes32 active) = probe.buybackState();
        return keccak256(
            abi.encode(
                current.ticketCount,
                current.status,
                accounting,
                weth.balanceOf(diamond),
                token.balanceOf(diamond),
                hook.lockedLiquidity(),
                hook.pendingPermanentLiquidity(Currency.wrap(address(token))),
                hook.pendingPermanentLiquidity(Currency.wrap(address(weth))),
                active
            )
        );
    }

    function _observeLiquidity() private {
        uint128 current = hook.lockedLiquidity();
        if (current < lastLockedLiquidity) liquidityDecreased = true;
        lastLockedLiquidity = current;
    }

    function _containsCanonicalSwap(Vm.Log[] memory logs) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == manager && logs[i].topics.length != 0 && logs[i].topics[0] == SWAP_EVENT) {
                return true;
            }
        }
        return false;
    }

    function _currentRoundId() private view returns (uint256) {
        (bool success, bytes memory data) = diamond.staticcall(abi.encodeWithSignature("currentRoundId()"));
        return success ? abi.decode(data, (uint256)) : 0;
    }

    function _round(uint256 roundId) private view returns (Round memory current) {
        (bool success, bytes memory data) = diamond.staticcall(abi.encodeWithSignature("round(uint256)", roundId));
        if (success) current = abi.decode(data, (Round));
    }

    function _rewardTickets(uint256 roundId, address actor) private view returns (uint256) {
        (bool success, bytes memory data) =
            diamond.staticcall(abi.encodeWithSignature("rewardTickets(uint256,address)", roundId, actor));
        return success ? abi.decode(data, (uint256)) : 0;
    }

    function _requestRound(uint256 requestId) private view returns (uint256 roundId) {
        (bool success, bytes memory data) =
            diamond.staticcall(abi.encodeWithSignature("requestRecord(uint256)", requestId));
        if (!success || data.length < 32) return 0;
        assembly ("memory-safe") {
            roundId := mload(add(data, 0x20))
        }
    }

    function _boundedRound(uint256 seed) private view returns (uint256) {
        uint256 count = _currentRoundId();
        return count == 0 ? 0 : bound(seed, 1, count);
    }

    function _boundedTokenId(uint256 seed) private view returns (uint256) {
        uint256 minted = rewardNft.mintedSupply();
        return minted == 0 ? 0 : bound(seed, 1, minted);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _isActor(address account) private view returns (bool) {
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == account) return true;
        }
        return false;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _reserveContribution(uint256 reserve, uint256 cap, uint256 operationsFee) private pure returns (uint256) {
        uint256 headroom = reserve < cap ? cap - reserve : 0;
        return operationsFee < headroom ? operationsFee : headroom;
    }
}

contract CrottoProtocolInvariantTest is StdInvariant, AutomaticTicketBuybackFixture {
    CrottoProtocolHandler private handler;
    IInvariantProbe private probe;

    function setUp() public {
        _deployProtocol(true);
        _installLifecycleAndProbeFacets();
        probe = IInvariantProbe(address(diamond));

        PoolKey memory key = LibCanonicalPool.key(address(token), address(weth), address(hook), TICK_SPACING);
        handler = new CrottoProtocolHandler(
            InvariantProtocolRefs({
                diamond: address(diamond),
                token: address(token),
                rewardNft: address(rewardNft),
                weth: address(weth),
                hook: address(hook),
                wrapper: address(vrfWrapper),
                manager: address(manager),
                swapRouter: address(swapRouter),
                initialTreasury: treasury,
                guardian: guardian
            }),
            key
        );
        handler.seedActors();
        IERC173(address(diamond)).transferOwnership(address(handler));

        bytes4[] memory selectors = new bytes4[](33);
        selectors[0] = CrottoProtocolHandler.buyTickets.selector;
        selectors[1] = CrottoProtocolHandler.initializePOL.selector;
        selectors[2] = CrottoProtocolHandler.requestRandomness.selector;
        selectors[3] = CrottoProtocolHandler.expireLottery.selector;
        selectors[4] = CrottoProtocolHandler.fulfillRandomness.selector;
        selectors[5] = CrottoProtocolHandler.finalizeLottery.selector;
        selectors[6] = CrottoProtocolHandler.claimWinnings.selector;
        selectors[7] = CrottoProtocolHandler.claimPlayerRewards.selector;
        selectors[8] = CrottoProtocolHandler.claimCallerRewards.selector;
        selectors[9] = CrottoProtocolHandler.buyNewRewardNFT.selector;
        selectors[10] = CrottoProtocolHandler.buyInventoryRewardNFT.selector;
        selectors[11] = CrottoProtocolHandler.redeemRewardNFT.selector;
        selectors[12] = CrottoProtocolHandler.activateRewardNFT.selector;
        selectors[13] = CrottoProtocolHandler.transferRewardNFT.selector;
        selectors[14] = CrottoProtocolHandler.claimNFTReward.selector;
        selectors[15] = CrottoProtocolHandler.donatePOL.selector;
        selectors[16] = CrottoProtocolHandler.compoundPOL.selector;
        selectors[17] = CrottoProtocolHandler.swap.selector;
        selectors[18] = CrottoProtocolHandler.setBuybackConfiguration.selector;
        selectors[19] = CrottoProtocolHandler.setHookConfiguration.selector;
        selectors[20] = CrottoProtocolHandler.setRoundRewardRate.selector;
        selectors[21] = CrottoProtocolHandler.pauseActions.selector;
        selectors[22] = CrottoProtocolHandler.setActivationConfiguration.selector;
        selectors[23] = CrottoProtocolHandler.setTreasuryReceiver.selector;
        selectors[24] = CrottoProtocolHandler.unpauseActions.selector;
        selectors[25] = CrottoProtocolHandler.donateRewardNFT.selector;
        selectors[26] = CrottoProtocolHandler.setBuilderApproval.selector;
        selectors[27] = CrottoProtocolHandler.revokeBuilder.selector;
        selectors[28] = CrottoProtocolHandler.buyTicketsWithBuilder.selector;
        selectors[29] = CrottoProtocolHandler.claimBuilderFees.selector;
        selectors[30] = CrottoProtocolHandler.fundOperationsReserve.selector;
        selectors[31] = CrottoProtocolHandler.settleBuilderFees.selector;
        selectors[32] = CrottoProtocolHandler.claimExpiredRoundRefund.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_CustodyCoversEveryLiabilityClass() public view {
        InvariantAccountingView memory accounting = probe.protocolAccountingProbe();
        assertGe(
            weth.balanceOf(address(diamond)),
            accounting.winnerWeth + accounting.rewardWeth + accounting.bootstrapWeth + accounting.ticketEscrowWeth
                + accounting.expiredTicketRefundWeth + accounting.pendingBuybackWeth + accounting.lotteryNftWeth
        );
        assertGe(token.balanceOf(address(diamond)), accounting.rewardToken + accounting.vaultToken);
        assertGe(
            address(diamond).balance,
            accounting.operationsEth + accounting.callerCreditsEth + accounting.builderCreditsEth
        );
        assertGe(token.balanceOf(address(hook)), hook.pendingPermanentLiquidity(Currency.wrap(address(token))));
        assertGe(weth.balanceOf(address(hook)), hook.pendingPermanentLiquidity(Currency.wrap(address(weth))));

        uint256 winnerLiabilities;
        uint256 playerLiabilities;
        uint256 currentRoundId = _currentRoundId();
        for (uint256 roundId = 1; roundId <= currentRoundId; ++roundId) {
            Round memory current = _round(roundId);
            assertLe(current.ticketCount, current.config.ticketTarget);
            uint256 rewardTicketTotal;
            for (uint256 i; i < 4; ++i) {
                rewardTicketTotal += _rewardTickets(roundId, handler.actors(i));
            }
            assertEq(rewardTicketTotal, current.ticketCount);
            for (uint256 i; i < 4; ++i) {
                address builder = handler.actors(i);
                assertEq(
                    ICrottoBuilderFees(address(diamond)).provisionalBuilderCredit(roundId, builder),
                    handler.modeledProvisionalBuilderCredits(roundId, builder)
                );
            }
            if (!current.prizeClaimed) winnerLiabilities += current.winnerPoolWeth;
            playerLiabilities += current.unclaimedPlayerRewardLiability;
        }
        assertEq(accounting.winnerWeth, winnerLiabilities);
        assertEq(accounting.playerToken, playerLiabilities);
        assertEq(accounting.builderCreditsEth, handler.modeledBuilderLiability());
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(ICrottoBuilderFees(address(diamond)).builderCredit(actor), handler.modeledBuilderCredits(actor));
        }
    }

    function invariant_RandomnessWinnersAndClaimsRemainImmutable() public view {
        assertFalse(handler.randomnessChanged());
        assertFalse(handler.winnerChanged());
        uint256 currentRoundId = _currentRoundId();
        for (uint256 roundId = 1; roundId <= currentRoundId; ++roundId) {
            Round memory current = _round(roundId);
            if (handler.acceptedWordRecorded(roundId)) {
                assertEq(current.acceptedRandomWord, handler.acceptedWords(roundId));
            }
            address winner = handler.finalizedWinners(roundId);
            if (winner != address(0)) {
                assertEq(current.winner, winner);
                assertEq(current.winningTicket + 1, handler.finalizedTickets(roundId));
            }
            assertLe(handler.winnerClaimCount(roundId), 1);
            for (uint256 i; i < 4; ++i) {
                assertLe(handler.playerClaimCount(roundId, handler.actors(i)), 1);
            }
        }
    }

    function invariant_RewardWeightsAndVaultBackingStayExact() public view {
        uint256 storedWeight;
        uint256 minted = rewardNft.mintedSupply();
        for (uint256 tokenId = 1; tokenId <= minted; ++tokenId) {
            storedWeight += ICrottoRewards(address(diamond)).nftRewardPosition(tokenId).storedWeight;
        }
        assertEq(ICrottoRewards(address(diamond)).totalActiveWeight(), storedWeight);

        VaultAccountingView memory accounting = INFTVault(address(diamond)).vaultAccounting();
        assertGe(accounting.vaultTokenBacking, accounting.requiredTokenBacking);
        assertEq(accounting.requiredTokenBacking, accounting.circulatingNfts * accounting.vaultPrice);
    }

    function invariant_MintingPOLAndBuybacksRemainIsolated() public view {
        assertEq(token.GENESIS_TREASURY_SUPPLY(), 10_000_000 ether);
        assertLe(handler.bootstrapMintCount(), 1);
        if (token.bootstrapMintExecuted()) {
            assertEq(handler.bootstrapMintCount(), 1);
            assertEq(handler.bootstrapMintAmount(), pol.bootstrapTokenMintAmount());
        }
        assertEq(
            token.totalSupply(),
            token.GENESIS_TREASURY_SUPPLY() + handler.bootstrapMintAmount() + handler.playerRewardsMinted()
                - handler.activationTokensBurned()
        );
        (uint256 reserved0, uint256 reserved1, uint256 reserved2, bytes32 active) = probe.buybackState();
        assertEq(reserved0, 0);
        assertEq(reserved1, 0);
        assertEq(reserved2, 0);
        assertEq(active, bytes32(0));
        assertFalse(handler.buybackBudgetViolation());
        assertFalse(handler.purchaseRollbackViolation());
        assertFalse(handler.operationsRoutingViolation());
    }

    function invariant_PermanentLiquidityNeverDecreases() public view {
        assertFalse(handler.liquidityDecreased());
        assertEq(hook.lockedLiquidity(), handler.lastLockedLiquidity());
        if (pol.polInitialized()) {
            assertTrue(hook.poolInitialized());
            assertEq(PoolId.unwrap(hook.canonicalPoolId()), PoolId.unwrap(pol.canonicalPoolId()));
            assertEq(hook.canonicalPoolKey().fee, 0);
        }
    }

    function _installLifecycleAndProbeFacets() private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _facetCut(
            address(new OperationsFacet()), _artifactSelectors("out/OperationsFacet.sol/OperationsFacet.json")
        );
        cuts[1] =
            _facetCut(address(new NFTVaultFacet()), _artifactSelectors("out/NFTVaultFacet.sol/NFTVaultFacet.json"));
        cuts[2] = _facetCut(
            address(new InvariantProbeFacet()),
            _artifactSelectors("out/CrottoProtocolInvariant.t.sol/InvariantProbeFacet.json")
        );
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function _rewardNftMaxSupply() internal pure override returns (uint256) {
        return 4;
    }

    function _currentRoundId() private view returns (uint256 current) {
        (bool success, bytes memory data) = address(diamond).staticcall(abi.encodeWithSignature("currentRoundId()"));
        if (success) current = abi.decode(data, (uint256));
    }

    function _round(uint256 roundId) private view returns (Round memory current) {
        (bool success, bytes memory data) =
            address(diamond).staticcall(abi.encodeWithSignature("round(uint256)", roundId));
        if (success) current = abi.decode(data, (Round));
    }

    function _rewardTickets(uint256 roundId, address beneficiary) private view returns (uint256 count) {
        (bool success, bytes memory data) =
            address(diamond).staticcall(abi.encodeWithSignature("rewardTickets(uint256,address)", roundId, beneficiary));
        if (success) count = abi.decode(data, (uint256));
    }
}
