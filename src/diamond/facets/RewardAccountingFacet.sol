// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ICrottoRewards} from "../../interfaces/ICrottoRewards.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibRewardAccounting} from "../../libraries/LibRewardAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {NFTRewardPosition, RewardBook} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Two-asset Reward NFT books, views, and authenticated hook revenue routing.
contract RewardAccountingFacet is CrottoFacet {
    error UnauthorizedCanonicalHook(address caller, address expectedHook);
    error InvalidRewardAsset(address asset);

    /// @notice Pulls and indexes only the Reward NFT leg already allocated by the canonical hook.
    /// @dev The hook transfers its treasury leg directly to the external Treasury Receiver before this call.
    ///      `treasuryAmount` is emitted as reconciliation metadata and is never pulled or transferred here.
    /// @param asset Configured WETH or ActivationToken reward asset.
    /// @param rewardAmount Exact Reward NFT allocation to pull from the canonical hook and index.
    /// @param treasuryAmount Treasury allocation already transferred directly by the canonical hook.
    function routeHookRevenue(address asset, uint256 rewardAmount, uint256 treasuryAmount) external nonReentrant {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        address canonicalHook = governance.immutableConfiguration.canonicalHook;
        if (msg.sender != canonicalHook) revert UnauthorizedCanonicalHook(msg.sender, canonicalHook);

        address weth = governance.immutableConfiguration.weth;
        address token = governance.immutableConfiguration.activationToken;
        if (asset != weth && asset != token) revert InvalidRewardAsset(asset);

        if (rewardAmount != 0) {
            if (LibRewardsStorage.layout().totalActiveWeight == 0) revert LibRewardAccounting.NoActiveRewardWeight();
            LibAssetTransfer.pullExact(asset, msg.sender, rewardAmount);
            if (asset == weth) LibRewardAccounting.accrueWeth(rewardAmount);
            else LibRewardAccounting.accrueToken(rewardAmount);
        }

        emit ICrottoRewards.HookRevenueRouted(asset, rewardAmount, treasuryAmount);
    }

    function totalActiveWeight() external view returns (uint256) {
        return LibRewardsStorage.layout().totalActiveWeight;
    }

    function wethRewardBook() external view returns (RewardBook memory) {
        return LibRewardsStorage.layout().wethBook;
    }

    function tokenRewardBook() external view returns (RewardBook memory) {
        return LibRewardsStorage.layout().tokenBook;
    }

    function nftRewardPosition(uint256 tokenId) external view returns (NFTRewardPosition memory) {
        return LibRewardsStorage.layout().positions[tokenId];
    }

    function pendingNFTRewards(uint256 tokenId) external view returns (uint256 wethAmount, uint256 tokenAmount) {
        return LibRewardAccounting.pending(tokenId);
    }
}
