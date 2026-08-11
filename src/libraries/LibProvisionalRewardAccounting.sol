// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CrottoConstants} from "./CrottoConstants.sol";
import {LibAssetTransfer} from "./LibAssetTransfer.sol";
import {LibGovernanceStorage} from "./storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "./storage/LibLotteryStorage.sol";
import {LibRewardsStorage} from "./storage/LibRewardsStorage.sol";
import {LibRoundSettlementStorage} from "./storage/LibRoundSettlementStorage.sol";
import {ProvisionalNFTRewardPosition, RoundSettlement, RoundStatus} from "../types/CrottoTypes.sol";

/// @notice Purchase-time Reward NFT eligibility whose WETH becomes claimable only on round success.
library LibProvisionalRewardAccounting {
    error NoActiveRewardWeight();

    function accrue(uint256 roundId, uint256 amount, uint256 denominator) internal {
        if (amount == 0) return;
        if (denominator == 0) revert NoActiveRewardWeight();

        RoundSettlement storage settlement = LibRoundSettlementStorage.layout().rounds[roundId];
        (uint256 delta, uint256 remainder) = _indexDelta(amount, settlement.provisionalNftRemainder, denominator);
        settlement.provisionalNftIndexRay += delta;
        settlement.provisionalNftRemainder = remainder;
        settlement.rewardNftWeth += amount;
    }

    function beforeWeightChange(uint256 tokenId, uint256 oldWeight) internal {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        ProvisionalNFTRewardPosition storage position = state.nftPositions[tokenId];
        uint256 currentRoundId = LibLotteryStorage.layout().currentRoundId;

        _settleResolvedRounds(position, oldWeight, currentRoundId, state);
        _settleCurrentRound(position, oldWeight, currentRoundId, state.rounds[currentRoundId]);
    }

    function afterWeightChange(uint256 tokenId, bool denominatorChanged) internal {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        uint256 currentRoundId = LibLotteryStorage.layout().currentRoundId;
        ProvisionalNFTRewardPosition storage position = state.nftPositions[tokenId];
        position.provisionalRoundId = currentRoundId;
        position.provisionalCheckpointRay = state.rounds[currentRoundId].provisionalNftIndexRay;
        if (denominatorChanged) state.rounds[currentRoundId].provisionalNftRemainder = 0;
    }

    function settleFinalized(uint256 tokenId, uint256 weight) internal returns (uint256 amount) {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        ProvisionalNFTRewardPosition storage position = state.nftPositions[tokenId];
        _settleResolvedRounds(position, weight, LibLotteryStorage.layout().currentRoundId, state);
        amount = position.claimableWeth;
    }

    function consumeClaim(uint256 tokenId, uint256 weight) internal returns (uint256 amount) {
        settleFinalized(tokenId, weight);
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        ProvisionalNFTRewardPosition storage position = state.nftPositions[tokenId];
        amount = position.claimableWeth;
        if (amount == 0) return 0;
        position.claimableWeth = 0;
        state.lotteryNftWethLiability -= amount;
        state.lotteryNftClaimableWeth -= amount;
    }

    function pending(uint256 tokenId, uint256 weight) internal view returns (uint256 amount) {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        ProvisionalNFTRewardPosition storage stored = state.nftPositions[tokenId];
        ProvisionalNFTRewardPosition memory position = stored;
        uint256 currentRoundId = LibLotteryStorage.layout().currentRoundId;

        if (position.provisionalRoundId != 0 && position.provisionalRoundId != currentRoundId) {
            RoundStatus status = LibLotteryStorage.layout().rounds[position.provisionalRoundId].status;
            RoundSettlement storage prior = state.rounds[position.provisionalRoundId];
            if (status == RoundStatus.Finalized) {
                amount += position.provisionalClaimableWeth;
                if (weight != 0 && prior.provisionalNftIndexRay > position.provisionalCheckpointRay) {
                    amount += Math.mulDiv(
                        weight, prior.provisionalNftIndexRay - position.provisionalCheckpointRay, CrottoConstants.RAY
                    );
                }
                position.finalizedCheckpointRay = prior.finalizedNftIndexRay;
            }
            position.provisionalRoundId = 0;
        }

        amount += position.claimableWeth;
        if (weight != 0 && state.finalizedNftIndexRay > position.finalizedCheckpointRay) {
            amount += Math.mulDiv(
                weight, state.finalizedNftIndexRay - position.finalizedCheckpointRay, CrottoConstants.RAY
            );
        }
    }

    function commitRound(uint256 roundId) internal {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        RoundSettlement storage settlement = state.rounds[roundId];
        state.finalizedNftIndexRay += settlement.provisionalNftIndexRay;
        settlement.finalizedNftIndexRay = state.finalizedNftIndexRay;
        state.lotteryNftWethLiability += settlement.rewardNftWeth;
        state.lotteryNftClaimableWeth += settlement.provisionalNftCrystallizedWeth;
        if (LibRewardsStorage.layout().totalActiveWeight == 0) finishEpoch();
    }

    function discardRound(uint256 roundId) internal {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        state.rounds[roundId].finalizedNftIndexRay = state.finalizedNftIndexRay;
    }

    function finishEpoch() internal {
        LibRoundSettlementStorage.Layout storage state = LibRoundSettlementStorage.layout();
        uint256 dust = state.lotteryNftWethLiability - state.lotteryNftClaimableWeth;
        if (dust == 0) return;
        state.lotteryNftWethLiability -= dust;
        LibAssetTransfer.pushExact(
            LibGovernanceStorage.layout().immutableConfiguration.weth,
            LibGovernanceStorage.layout().treasuryReceiver,
            dust
        );
    }

    function _settleResolvedRounds(
        ProvisionalNFTRewardPosition storage position,
        uint256 weight,
        uint256 currentRoundId,
        LibRoundSettlementStorage.Layout storage state
    ) private {
        uint256 provisionalRoundId = position.provisionalRoundId;
        if (provisionalRoundId != 0 && provisionalRoundId != currentRoundId) {
            RoundStatus status = LibLotteryStorage.layout().rounds[provisionalRoundId].status;
            RoundSettlement storage prior = state.rounds[provisionalRoundId];
            if (status == RoundStatus.Finalized) {
                uint256 amount = position.provisionalClaimableWeth;
                if (weight != 0 && prior.provisionalNftIndexRay > position.provisionalCheckpointRay) {
                    uint256 lazyAmount = Math.mulDiv(
                        weight, prior.provisionalNftIndexRay - position.provisionalCheckpointRay, CrottoConstants.RAY
                    );
                    amount += lazyAmount;
                    state.lotteryNftClaimableWeth += lazyAmount;
                }
                if (amount != 0) position.claimableWeth += amount;
                position.finalizedCheckpointRay = prior.finalizedNftIndexRay;
            } else if (status != RoundStatus.Expired) {
                return;
            }
            position.provisionalRoundId = 0;
            position.provisionalCheckpointRay = 0;
            position.provisionalClaimableWeth = 0;
        }

        if (weight != 0 && state.finalizedNftIndexRay > position.finalizedCheckpointRay) {
            uint256 finalizedAmount =
                Math.mulDiv(weight, state.finalizedNftIndexRay - position.finalizedCheckpointRay, CrottoConstants.RAY);
            if (finalizedAmount != 0) {
                position.claimableWeth += finalizedAmount;
                state.lotteryNftClaimableWeth += finalizedAmount;
            }
        }
        position.finalizedCheckpointRay = state.finalizedNftIndexRay;
    }

    function _settleCurrentRound(
        ProvisionalNFTRewardPosition storage position,
        uint256 weight,
        uint256 currentRoundId,
        RoundSettlement storage current
    ) private {
        if (position.provisionalRoundId != currentRoundId) {
            position.provisionalRoundId = currentRoundId;
            if (weight != 0 && current.provisionalNftIndexRay != 0) {
                uint256 amount = Math.mulDiv(weight, current.provisionalNftIndexRay, CrottoConstants.RAY);
                position.provisionalClaimableWeth = amount;
                current.provisionalNftCrystallizedWeth += amount;
            } else {
                position.provisionalClaimableWeth = 0;
            }
            position.provisionalCheckpointRay = current.provisionalNftIndexRay;
            return;
        }
        if (weight != 0 && current.provisionalNftIndexRay > position.provisionalCheckpointRay) {
            uint256 amount = Math.mulDiv(
                weight, current.provisionalNftIndexRay - position.provisionalCheckpointRay, CrottoConstants.RAY
            );
            position.provisionalClaimableWeth += amount;
            current.provisionalNftCrystallizedWeth += amount;
        }
        position.provisionalCheckpointRay = current.provisionalNftIndexRay;
    }

    function _indexDelta(uint256 amount, uint256 priorRemainder, uint256 denominator)
        private
        pure
        returns (uint256 delta, uint256 remainder)
    {
        delta = Math.mulDiv(amount, CrottoConstants.RAY, denominator);
        remainder = mulmod(amount, CrottoConstants.RAY, denominator);
        delta += priorRemainder / denominator;
        uint256 normalizedPrior = priorRemainder % denominator;
        uint256 room = denominator - normalizedPrior;
        if (remainder >= room) {
            ++delta;
            remainder -= room;
        } else {
            remainder += normalizedPrior;
        }
    }
}
