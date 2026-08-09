// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IActivationToken} from "../../interfaces/IActivationToken.sol";
import {ICrottoRewards} from "../../interfaces/ICrottoRewards.sol";
import {IRewardNFT} from "../../interfaces/IRewardNFT.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {ActivationConfiguration, NFTRewardPosition} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Sequential Reward NFT activation using the current governed economics.
contract RewardActivationFacet is CrottoFacet {
    error NotRewardNFTOwner(uint256 tokenId, address caller, address owner);
    error MaximumTierReached(uint256 tokenId);

    function activateNextTier(uint256 tokenId)
        external
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_NFT_ACTIVATIONS)
    {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        address rewardNft = governance.immutableConfiguration.rewardNFT;
        address token = governance.immutableConfiguration.activationToken;
        address owner = IRewardNFT(rewardNft).ownerOf(tokenId);
        if (owner != msg.sender) revert NotRewardNFTOwner(tokenId, msg.sender, owner);

        LibRewardsStorage.Layout storage rewards = LibRewardsStorage.layout();
        NFTRewardPosition storage position = rewards.positions[tokenId];
        uint8 previousTier = position.tier;
        if (previousTier == 3) revert MaximumTierReached(tokenId);

        _settleNftRewards(tokenId);

        ActivationConfiguration storage configuration = governance.activationConfiguration;
        uint256 cost = configuration.costs[previousTier];
        uint256 destinationWeight = configuration.destinationWeights[previousTier];
        uint64 configurationVersion = governance.activationConfigurationVersion;

        LibAssetTransfer.pullExact(token, msg.sender, cost);

        uint256 burned = Math.mulDiv(cost, configuration.burnShareBps, CrottoConstants.BPS);
        uint256 nftAllocation = Math.mulDiv(cost, configuration.nftShareBps, CrottoConstants.BPS);
        uint256 treasuryAmount = cost - burned - nftAllocation;
        if (burned != 0) IActivationToken(token).burn(burned);

        uint256 indexedNftRewards;
        if (rewards.totalActiveWeight == 0) {
            treasuryAmount += nftAllocation;
        } else {
            indexedNftRewards = nftAllocation;
            _accrueNftTokenRewards(nftAllocation);
        }

        LibAssetTransfer.pushExact(token, governance.treasuryReceiver, treasuryAmount);

        uint8 newTier = previousTier + 1;
        _setNftRewardWeight(tokenId, newTier, destinationWeight);

        emit ICrottoRewards.ActivationFeeRouted(tokenId, burned, indexedNftRewards, treasuryAmount);
        emit ICrottoRewards.NFTTierActivated(
            tokenId, previousTier, newTier, cost, destinationWeight, configurationVersion
        );
    }
}
