// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IActivationToken} from "../../interfaces/IActivationToken.sol";
import {ICrotto} from "../../interfaces/ICrotto.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibLottery} from "../../libraries/LibLottery.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibProvisionalRewardAccounting} from "../../libraries/LibProvisionalRewardAccounting.sol";
import {LibTicketQueue} from "../../libraries/LibTicketQueue.sol";
import {LibWethSolvency} from "../../libraries/LibWethSolvency.sol";
import {ICrottoSwapFeeHook} from "../../interfaces/ICrottoSwapFeeHook.sol";
import {LibBuilderFeesStorage} from "../../libraries/storage/LibBuilderFeesStorage.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "../../libraries/storage/LibPOLStorage.sol";
import {LibRoundSettlementStorage} from "../../libraries/storage/LibRoundSettlementStorage.sol";
import {Round, RoundSettlement, RoundStatus, TicketBatch} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Permissionless winner resolution, round rollover, and independent pull claims.
contract LotteryFinalizationFacet is CrottoFacet {
    using SafeERC20 for IERC20;

    error UnknownRound(uint256 roundId);
    error RoundNotReadyForFinalization(uint256 roundId, RoundStatus status);
    error RoundNotFinalized(uint256 roundId, RoundStatus status);
    error InvalidTicketBatches(uint256 roundId);
    error NotLotteryWinner(uint256 roundId, address caller, address winner);
    error PrizeAlreadyClaimed(uint256 roundId);
    error PlayerRewardUnavailable(uint256 roundId, address player);
    error PlayerRewardAlreadyClaimed(uint256 roundId, address player);
    error InvalidLotteryClaimReceiver(address receiver);
    error PlayerRewardMintMismatch(uint256 expected, uint256 balanceIncrease, uint256 supplyIncrease);
    error RoundNotExpirable(uint256 roundId, RoundStatus status);
    error RoundTimeoutNotReached(uint256 roundId, uint256 currentBlock, uint256 firstExpirableBlock);
    error RefundAlreadyClaimed(uint256 roundId, address buyer);
    error RefundUnavailable(uint256 roundId, address buyer);
    error NativeRefundTransferFailed(address receiver, uint256 amount);
    error UnexpectedNativeRefundDebit(uint256 expected, uint256 actual);
    error UnexpectedHookAllowance(uint256 allowance);

    function finalizeLottery(uint256 roundId) external nonReentrant {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage currentRound = _round(lottery, roundId);
        if (currentRound.status != RoundStatus.RandomReady) {
            revert RoundNotReadyForFinalization(roundId, currentRound.status);
        }

        uint256 ticketCount = currentRound.ticketCount;
        uint256 winningTicket = currentRound.acceptedRandomWord % ticketCount;
        address winner = _winner(lottery.ticketBatches[roundId], roundId, winningTicket);
        uint256 playerLiability = ticketCount * currentRound.config.playerRewardRate;

        currentRound.winningTicket = winningTicket;
        currentRound.winner = winner;
        currentRound.totalPlayerRewardLiability = playerLiability;
        currentRound.unclaimedPlayerRewardLiability = playerLiability;
        currentRound.status = RoundStatus.Finalized;
        lottery.totalPlayerTokenLiability += playerLiability;

        _commitEconomicSettlement(roundId, currentRound);

        LibOperationsAccounting.creditFinalization(msg.sender, roundId, currentRound.config.finalizationCallerReward);
        LibLottery.initializeNextRound(roundId, LibGovernanceStorage.layout().roundConfiguration);
        LibTicketQueue.processNewRound();
        LibOperationsAccounting.enforceNativeSolvency();
        LibWethSolvency.enforce();

        emit ICrotto.LotteryFinalized(roundId, winningTicket, winner, currentRound.winnerPoolWeth, playerLiability);
    }

    function expireLottery(uint256 roundId) external nonReentrant {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage currentRound = _round(lottery, roundId);
        uint256 deadline;
        if (currentRound.status == RoundStatus.Closed) {
            deadline = uint256(currentRound.closedAtBlock) + currentRound.config.vrfTimeoutBlocks;
        } else if (currentRound.status == RoundStatus.VRFPending) {
            deadline = uint256(currentRound.latestRequestBlock) + currentRound.config.vrfTimeoutBlocks;
        } else {
            revert RoundNotExpirable(roundId, currentRound.status);
        }
        if (block.number <= deadline) revert RoundTimeoutNotReached(roundId, block.number, deadline + 1);

        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        RoundSettlement storage settlement = settlements.rounds[roundId];
        currentRound.status = RoundStatus.Expired;
        settlements.activeTicketEscrowWeth -= settlement.ticketEscrowWeth;
        settlements.expiredTicketRefundWeth += settlement.ticketEscrowWeth;
        LibProvisionalRewardAccounting.discardRound(roundId);

        LibBuilderFeesStorage.Layout storage builders = LibBuilderFeesStorage.layout();
        builders.provisionalNativeEthLiability -= settlement.builderFeeEth;
        settlements.expiredBuilderRefundEth += settlement.builderFeeEth;

        LibOperationsAccounting.creditExpiration(msg.sender, roundId, currentRound.config.finalizationCallerReward);
        LibLottery.initializeNextRound(roundId, LibGovernanceStorage.layout().roundConfiguration);
        LibTicketQueue.processNewRound();
        LibOperationsAccounting.enforceNativeSolvency();
        LibWethSolvency.enforce();
        emit ICrotto.LotteryExpired(roundId, settlement.ticketEscrowWeth, settlement.builderFeeEth, msg.sender);
    }

    function claimExpiredRoundRefund(uint256 roundId, address wethReceiver, address nativeReceiver)
        external
        nonReentrant
        returns (uint256 ticketRefundWeth, uint256 builderRefundEth)
    {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage expiredRound = _round(lottery, roundId);
        if (expiredRound.status != RoundStatus.Expired) revert RoundNotFinalized(roundId, expiredRound.status);

        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        if (settlements.refundClaimed[roundId][msg.sender]) revert RefundAlreadyClaimed(roundId, msg.sender);
        ticketRefundWeth = lottery.playerTicketCounts[roundId][msg.sender] * expiredRound.config.ticketPrice;
        builderRefundEth = settlements.builderRefundEth[roundId][msg.sender];
        if (ticketRefundWeth == 0 && builderRefundEth == 0) revert RefundUnavailable(roundId, msg.sender);
        if (ticketRefundWeth != 0) _validateReceiver(wethReceiver);
        if (builderRefundEth != 0) _validateReceiver(nativeReceiver);

        settlements.refundClaimed[roundId][msg.sender] = true;
        settlements.expiredTicketRefundWeth -= ticketRefundWeth;
        settlements.expiredBuilderRefundEth -= builderRefundEth;
        LibBuilderFeesStorage.layout().totalNativeEthLiability -= builderRefundEth;

        if (ticketRefundWeth != 0) {
            LibAssetTransfer.pushExact(
                LibGovernanceStorage.layout().immutableConfiguration.weth, wethReceiver, ticketRefundWeth
            );
        }
        if (builderRefundEth != 0) {
            uint256 balanceBefore = address(this).balance;
            if (!_sendNative(nativeReceiver, builderRefundEth)) {
                revert NativeRefundTransferFailed(nativeReceiver, builderRefundEth);
            }
            uint256 balanceAfter = address(this).balance;
            uint256 debit = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
            if (debit != builderRefundEth) revert UnexpectedNativeRefundDebit(builderRefundEth, debit);
        }
        LibOperationsAccounting.enforceNativeSolvency();
        LibWethSolvency.enforce();
        emit ICrotto.ExpiredRoundRefundClaimed(
            roundId, msg.sender, wethReceiver, nativeReceiver, ticketRefundWeth, builderRefundEth
        );
    }

    function claimWinnings(uint256 roundId, address receiver) external nonReentrant returns (uint256 amount) {
        _validateReceiver(receiver);
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage finalizedRound = _round(lottery, roundId);
        if (finalizedRound.status != RoundStatus.Finalized) {
            revert RoundNotFinalized(roundId, finalizedRound.status);
        }
        if (msg.sender != finalizedRound.winner) {
            revert NotLotteryWinner(roundId, msg.sender, finalizedRound.winner);
        }
        if (finalizedRound.prizeClaimed) revert PrizeAlreadyClaimed(roundId);

        amount = finalizedRound.winnerPoolWeth;
        finalizedRound.prizeClaimed = true;
        lottery.totalWinnerPoolWethLiability -= amount;
        LibAssetTransfer.pushExact(LibGovernanceStorage.layout().immutableConfiguration.weth, receiver, amount);
        LibWethSolvency.enforce();

        emit ICrotto.WinningsClaimed(roundId, msg.sender, receiver, amount);
    }

    function claimPlayerRewards(uint256 roundId, address receiver) external nonReentrant returns (uint256 amount) {
        _validateReceiver(receiver);
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage finalizedRound = _round(lottery, roundId);
        if (finalizedRound.status != RoundStatus.Finalized) {
            revert RoundNotFinalized(roundId, finalizedRound.status);
        }
        if (lottery.playerRewardClaimed[roundId][msg.sender]) {
            revert PlayerRewardAlreadyClaimed(roundId, msg.sender);
        }

        amount = lottery.rewardTicketCounts[roundId][msg.sender] * finalizedRound.config.playerRewardRate;
        if (amount == 0) revert PlayerRewardUnavailable(roundId, msg.sender);
        lottery.playerRewardClaimed[roundId][msg.sender] = true;
        finalizedRound.unclaimedPlayerRewardLiability -= amount;
        lottery.totalPlayerTokenLiability -= amount;
        _mintPlayerReward(receiver, amount);

        emit ICrotto.PlayerRewardsClaimed(roundId, msg.sender, receiver, amount);
    }

    function _winner(TicketBatch[] storage batches, uint256 roundId, uint256 winningTicket)
        private
        view
        returns (address winner)
    {
        uint256 low;
        uint256 high = batches.length;
        if (high == 0 || batches[high - 1].endExclusive <= winningTicket) revert InvalidTicketBatches(roundId);

        while (low < high) {
            uint256 midpoint = low + (high - low) / 2;
            if (batches[midpoint].endExclusive > winningTicket) high = midpoint;
            else low = midpoint + 1;
        }
        winner = batches[low].buyer;
        if (winner == address(0)) revert InvalidTicketBatches(roundId);
    }

    function _mintPlayerReward(address receiver, uint256 amount) private {
        address tokenAddress = LibGovernanceStorage.layout().immutableConfiguration.activationToken;
        IERC20 token = IERC20(tokenAddress);
        uint256 balanceBefore = token.balanceOf(receiver);
        uint256 supplyBefore = token.totalSupply();
        IActivationToken(tokenAddress).mintPlayerReward(receiver, amount);
        uint256 balanceAfter = token.balanceOf(receiver);
        uint256 supplyAfter = token.totalSupply();
        uint256 balanceIncrease = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        uint256 supplyIncrease = supplyAfter >= supplyBefore ? supplyAfter - supplyBefore : 0;
        if (balanceIncrease != amount || supplyIncrease != amount) {
            revert PlayerRewardMintMismatch(amount, balanceIncrease, supplyIncrease);
        }
    }

    function _commitEconomicSettlement(uint256 roundId, Round storage currentRound) private {
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        RoundSettlement storage settlement = settlements.rounds[roundId];
        settlements.activeTicketEscrowWeth -= settlement.ticketEscrowWeth;

        currentRound.winnerPoolWeth = settlement.winnerWeth;
        LibLotteryStorage.layout().totalWinnerPoolWethLiability += settlement.winnerWeth;
        LibProvisionalRewardAccounting.commitRound(roundId);

        address weth = LibGovernanceStorage.layout().immutableConfiguration.weth;
        if (settlement.treasuryWeth != 0) {
            LibAssetTransfer.pushExact(weth, LibGovernanceStorage.layout().treasuryReceiver, settlement.treasuryWeth);
        }
        if (settlement.bootstrapPolWeth != 0) {
            LibPOLStorage.Layout storage pol = LibPOLStorage.layout();
            if (!pol.initialized) {
                pol.bootstrapWeth += settlement.bootstrapPolWeth;
            } else {
                address hook = LibGovernanceStorage.layout().immutableConfiguration.canonicalHook;
                IERC20(weth).forceApprove(hook, settlement.bootstrapPolWeth);
                ICrottoSwapFeeHook(hook).creditPOLWeth(settlement.bootstrapPolWeth);
                uint256 allowance = IERC20(weth).allowance(address(this), hook);
                if (allowance != 0) revert UnexpectedHookAllowance(allowance);
            }
        }
        if (settlement.buybackWeth != 0) {
            settlements.pendingBuybackWeth += settlement.buybackWeth;
        }
    }

    function _validateReceiver(address receiver) private view {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidLotteryClaimReceiver(receiver);
    }

    function _sendNative(address receiver, uint256 amount) private returns (bool success) {
        assembly ("memory-safe") {
            success := call(gas(), receiver, amount, 0, 0, 0, 0)
        }
    }

    function _round(LibLotteryStorage.Layout storage lottery, uint256 roundId)
        private
        view
        returns (Round storage storedRound)
    {
        if (roundId == 0 || roundId > lottery.currentRoundId) revert UnknownRound(roundId);
        storedRound = lottery.rounds[roundId];
    }
}
