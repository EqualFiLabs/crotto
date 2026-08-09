// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICrottoRewards} from "../../interfaces/ICrottoRewards.sol";
import {LibRewardAccounting} from "../../libraries/LibRewardAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {NFTRewardPosition, RewardBook} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Two-asset Reward NFT books, views, and authenticated hook revenue routing.
contract RewardAccountingFacet is CrottoFacet {
    using SafeERC20 for IERC20;

    error UnauthorizedCanonicalHook(address caller, address expectedHook);
    error InvalidRewardAsset(address asset);
    error UnexpectedRewardTokenDebit(address asset, uint256 expected, uint256 actual);
    error UnexpectedRewardTokenReceipt(address asset, uint256 expected, uint256 actual);

    function routeHookRevenue(address asset, uint256 rewardAmount, uint256 treasuryAmount) external nonReentrant {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        address canonicalHook = governance.immutableConfiguration.canonicalHook;
        if (msg.sender != canonicalHook) revert UnauthorizedCanonicalHook(msg.sender, canonicalHook);

        address weth = governance.immutableConfiguration.weth;
        address token = governance.immutableConfiguration.activationToken;
        if (asset != weth && asset != token) revert InvalidRewardAsset(asset);

        if (rewardAmount != 0) {
            if (LibRewardsStorage.layout().totalActiveWeight == 0) revert LibRewardAccounting.NoActiveRewardWeight();
            _pullExact(asset, rewardAmount);
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

    function _pullExact(address asset, uint256 amount) private {
        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(msg.sender);
        uint256 receiverBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 senderAfter = token.balanceOf(msg.sender);
        uint256 receiverAfter = token.balanceOf(address(this));

        uint256 senderDebit = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        if (senderDebit != amount) revert UnexpectedRewardTokenDebit(asset, amount, senderDebit);
        uint256 receiverReceipt = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (receiverReceipt != amount) revert UnexpectedRewardTokenReceipt(asset, amount, receiverReceipt);
    }
}
