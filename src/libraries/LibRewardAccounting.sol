// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICrottoRewards} from "../interfaces/ICrottoRewards.sol";
import {CrottoConstants} from "./CrottoConstants.sol";
import {LibAssetTransfer} from "./LibAssetTransfer.sol";
import {LibProvisionalRewardAccounting} from "./LibProvisionalRewardAccounting.sol";
import {LibGovernanceStorage} from "./storage/LibGovernanceStorage.sol";
import {LibRewardsStorage} from "./storage/LibRewardsStorage.sol";
import {NFTRewardPosition, RewardBook} from "../types/CrottoTypes.sol";

/// @notice Constant-time WETH and TOKEN accounting for Reward NFT positions.
library LibRewardAccounting {
    error NoActiveRewardWeight();
    error ActivePositionCheckpoint(uint256 tokenId);

    function accrueWeth(uint256 amount) internal returns (uint256 indexRay) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        return _accrue(
            state.wethBook, LibGovernanceStorage.layout().immutableConfiguration.weth, amount, state.totalActiveWeight
        );
    }

    function accrueToken(uint256 amount) internal returns (uint256 indexRay) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        return _accrue(
            state.tokenBook,
            LibGovernanceStorage.layout().immutableConfiguration.activationToken,
            amount,
            state.totalActiveWeight
        );
    }

    function settle(uint256 tokenId) internal returns (uint256 wethAmount, uint256 tokenAmount) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        NFTRewardPosition storage position = state.positions[tokenId];
        uint256 weight = position.storedWeight;

        LibProvisionalRewardAccounting.settleFinalized(tokenId, weight);

        if (weight != 0) {
            wethAmount = _settleBook(state.wethBook, weight, position.wethCheckpointRay);
            tokenAmount = _settleBook(state.tokenBook, weight, position.tokenCheckpointRay);

            if (wethAmount != 0) position.claimableWeth += wethAmount;
            if (tokenAmount != 0) position.claimableToken += tokenAmount;
        }

        position.wethCheckpointRay = state.wethBook.indexRay;
        position.tokenCheckpointRay = state.tokenBook.indexRay;
        emit ICrottoRewards.RewardSettled(tokenId, wethAmount, tokenAmount);
    }

    function pending(uint256 tokenId) internal view returns (uint256 wethAmount, uint256 tokenAmount) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        NFTRewardPosition storage position = state.positions[tokenId];
        wethAmount = position.claimableWeth;
        tokenAmount = position.claimableToken;
        wethAmount += LibProvisionalRewardAccounting.pending(tokenId, position.storedWeight);

        uint256 weight = position.storedWeight;
        if (weight == 0) return (wethAmount, tokenAmount);

        if (state.wethBook.indexRay > position.wethCheckpointRay) {
            wethAmount += Math.mulDiv(weight, state.wethBook.indexRay - position.wethCheckpointRay, CrottoConstants.RAY);
        }
        if (state.tokenBook.indexRay > position.tokenCheckpointRay) {
            tokenAmount += Math.mulDiv(
                weight, state.tokenBook.indexRay - position.tokenCheckpointRay, CrottoConstants.RAY
            );
        }
    }

    function consumeWethClaim(uint256 tokenId) internal returns (uint256 amount) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        settle(tokenId);
        NFTRewardPosition storage position = state.positions[tokenId];
        amount = position.claimableWeth;
        position.claimableWeth = 0;
        if (amount != 0) state.wethBook.totalClaimable -= amount;
        amount += LibProvisionalRewardAccounting.consumeClaim(tokenId, position.storedWeight);
    }

    function consumeTokenClaim(uint256 tokenId) internal returns (uint256 amount) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        settle(tokenId);
        NFTRewardPosition storage position = state.positions[tokenId];
        amount = position.claimableToken;
        if (amount == 0) return 0;
        position.claimableToken = 0;
        state.tokenBook.totalClaimable -= amount;
    }

    /// @dev Settles the old position, checkpoints current indexes, then changes its eligibility.
    function setPositionWeight(uint256 tokenId, uint8 tier, uint256 newWeight)
        internal
        returns (uint256 previousWeight)
    {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        NFTRewardPosition storage position = state.positions[tokenId];
        settle(tokenId);

        previousWeight = position.storedWeight;
        LibProvisionalRewardAccounting.beforeWeightChange(tokenId, previousWeight);
        if (previousWeight != newWeight) {
            state.totalActiveWeight = state.totalActiveWeight - previousWeight + newWeight;
            // A remainder is expressed against the denominator that produced it and cannot
            // be carried across an eligibility change. The underlying amount remains indexed
            // and is reconciled as dust when the epoch ends.
            state.wethBook.indexRemainder = 0;
            state.tokenBook.indexRemainder = 0;
        }

        position.tier = tier;
        position.storedWeight = newWeight;
        position.wethCheckpointRay = state.wethBook.indexRay;
        position.tokenCheckpointRay = state.tokenBook.indexRay;
        LibProvisionalRewardAccounting.afterWeightChange(tokenId, previousWeight != newWeight);

        if (state.totalActiveWeight == 0) {
            _finishEpoch(state);
            LibProvisionalRewardAccounting.finishEpoch();
        }
    }

    /// @dev Initializes or refreshes an ineligible position without changing attached claims.
    function checkpointPosition(uint256 tokenId) internal {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        NFTRewardPosition storage position = state.positions[tokenId];
        if (position.storedWeight != 0) revert ActivePositionCheckpoint(tokenId);
        position.wethCheckpointRay = state.wethBook.indexRay;
        position.tokenCheckpointRay = state.tokenBook.indexRay;
    }

    function outstanding(RewardBook storage book) internal view returns (uint256) {
        return book.indexedAmount - book.crystallizedAmount + book.totalClaimable;
    }

    function _accrue(RewardBook storage book, address asset, uint256 amount, uint256 denominator)
        private
        returns (uint256 indexRay)
    {
        if (amount == 0) return book.indexRay;
        if (denominator == 0) revert NoActiveRewardWeight();

        (uint256 delta, uint256 remainder) = _indexDelta(amount, book.indexRemainder, denominator);
        book.indexRemainder = remainder;
        book.indexRay += delta;
        book.indexedAmount += amount;

        emit ICrottoRewards.RewardAccrued(asset, amount, book.indexRay, denominator);
        return book.indexRay;
    }

    function _settleBook(RewardBook storage book, uint256 weight, uint256 checkpointRay)
        private
        returns (uint256 amount)
    {
        if (book.indexRay <= checkpointRay) return 0;
        amount = Math.mulDiv(weight, book.indexRay - checkpointRay, CrottoConstants.RAY);
        if (amount == 0) return 0;
        book.crystallizedAmount += amount;
        book.totalClaimable += amount;
    }

    function _finishEpoch(LibRewardsStorage.Layout storage state) private {
        _finishBook(state.wethBook, LibGovernanceStorage.layout().immutableConfiguration.weth);
        _finishBook(state.tokenBook, LibGovernanceStorage.layout().immutableConfiguration.activationToken);
    }

    function _finishBook(RewardBook storage book, address asset) private {
        uint256 dust = book.indexedAmount - book.crystallizedAmount;
        if (dust != 0) {
            address receiver = LibGovernanceStorage.layout().treasuryReceiver;
            LibAssetTransfer.pushExact(asset, receiver, dust);
            emit ICrottoRewards.RewardDustRouted(asset, receiver, dust);
        }

        book.indexRay = 0;
        book.indexRemainder = 0;
        book.indexedAmount = 0;
        book.crystallizedAmount = 0;
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
