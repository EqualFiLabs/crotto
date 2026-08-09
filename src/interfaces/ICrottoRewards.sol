// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {NFTRewardPosition, RewardBook} from "../types/CrottoTypes.sol";

/// @notice Activation, two-asset Reward NFT accounting, and authenticated satellite callbacks.
interface ICrottoRewards {
    event RewardAccrued(address indexed asset, uint256 amount, uint256 indexRay, uint256 totalActiveWeight);
    event RewardSettled(uint256 indexed tokenId, uint256 wethAmount, uint256 tokenAmount);
    event NFTTierActivated(
        uint256 indexed tokenId,
        uint8 indexed previousTier,
        uint8 indexed newTier,
        uint256 cost,
        uint256 storedWeight,
        uint64 configurationVersion
    );
    event ActivationFeeRouted(uint256 indexed tokenId, uint256 burned, uint256 nftRewards, uint256 treasuryAmount);
    event NFTActivationReset(uint256 indexed tokenId, address indexed from, address indexed to, uint256 removedWeight);
    event NFTRewardClaimed(uint256 indexed tokenId, address indexed asset, address indexed receiver, uint256 amount);
    event HookRevenueRouted(address indexed asset, uint256 rewardAmount, uint256 treasuryAmount);

    function activateNextTier(uint256 tokenId) external;

    function claimNFTWethReward(uint256 tokenId, address receiver) external returns (uint256 amount);

    function claimNFTTokenReward(uint256 tokenId, address receiver) external returns (uint256 amount);

    function onRewardNFTTransfer(address from, address to, uint256 tokenId) external;

    function routeHookRevenue(address asset, uint256 rewardAmount, uint256 treasuryAmount) external;

    function totalActiveWeight() external view returns (uint256);

    function wethRewardBook() external view returns (RewardBook memory);

    function tokenRewardBook() external view returns (RewardBook memory);

    function nftRewardPosition(uint256 tokenId) external view returns (NFTRewardPosition memory);

    function pendingNFTRewards(uint256 tokenId) external view returns (uint256 wethAmount, uint256 tokenAmount);
}
