// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IActivationToken} from "../../interfaces/IActivationToken.sol";
import {ICrotto} from "../../interfaces/ICrotto.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibLottery} from "../../libraries/LibLottery.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {Round, RoundStatus, TicketBatch} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Permissionless winner resolution, round rollover, and independent pull claims.
contract LotteryFinalizationFacet is CrottoFacet {
    error UnknownRound(uint256 roundId);
    error RoundNotReadyForFinalization(uint256 roundId, RoundStatus status);
    error InvalidTicketBatches(uint256 roundId);
    error NotLotteryWinner(uint256 roundId, address caller, address winner);
    error PrizeAlreadyClaimed(uint256 roundId);
    error PlayerRewardUnavailable(uint256 roundId, address player);
    error PlayerRewardAlreadyClaimed(uint256 roundId, address player);
    error InvalidLotteryClaimReceiver(address receiver);
    error PlayerRewardMintMismatch(uint256 expected, uint256 balanceIncrease, uint256 supplyIncrease);

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

        LibOperationsAccounting.creditFinalization(msg.sender, roundId, currentRound.config.finalizationCallerReward);
        LibLottery.initializeNextRound(roundId, LibGovernanceStorage.layout().roundConfiguration);
        LibOperationsAccounting.enforceNativeSolvency();

        emit ICrotto.LotteryFinalized(roundId, winningTicket, winner, currentRound.winnerPoolWeth, playerLiability);
    }

    function claimWinnings(uint256 roundId, address receiver) external nonReentrant returns (uint256 amount) {
        _validateReceiver(receiver);
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage finalizedRound = _round(lottery, roundId);
        if (finalizedRound.status != RoundStatus.Finalized) {
            revert RoundNotReadyForFinalization(roundId, finalizedRound.status);
        }
        if (msg.sender != finalizedRound.winner) {
            revert NotLotteryWinner(roundId, msg.sender, finalizedRound.winner);
        }
        if (finalizedRound.prizeClaimed) revert PrizeAlreadyClaimed(roundId);

        amount = finalizedRound.winnerPoolWeth;
        finalizedRound.prizeClaimed = true;
        lottery.totalWinnerPoolWethLiability -= amount;
        LibAssetTransfer.pushExact(LibGovernanceStorage.layout().immutableConfiguration.weth, receiver, amount);

        emit ICrotto.WinningsClaimed(roundId, msg.sender, receiver, amount);
    }

    function claimPlayerRewards(uint256 roundId, address receiver) external nonReentrant returns (uint256 amount) {
        _validateReceiver(receiver);
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        Round storage finalizedRound = _round(lottery, roundId);
        if (finalizedRound.status != RoundStatus.Finalized) {
            revert RoundNotReadyForFinalization(roundId, finalizedRound.status);
        }
        if (lottery.playerRewardClaimed[roundId][msg.sender]) {
            revert PlayerRewardAlreadyClaimed(roundId, msg.sender);
        }

        amount = lottery.playerTicketCounts[roundId][msg.sender] * finalizedRound.config.playerRewardRate;
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

    function _validateReceiver(address receiver) private view {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidLotteryClaimReceiver(receiver);
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
