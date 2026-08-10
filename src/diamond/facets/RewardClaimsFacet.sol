// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ICrottoRewards} from "../../interfaces/ICrottoRewards.sol";
import {IRewardNFT} from "../../interfaces/IRewardNFT.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibRewardAccounting} from "../../libraries/LibRewardAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Independent Reward NFT claims and authenticated transfer-reset accounting.
contract RewardClaimsFacet is CrottoFacet {
    error NotRewardNFTOwner(uint256 tokenId, address caller, address owner);
    error InvalidRewardReceiver(address receiver);

    function claimNFTWethReward(uint256 tokenId, address receiver) external nonReentrant returns (uint256 amount) {
        _validateClaim(tokenId, receiver);
        amount = LibRewardAccounting.consumeWethClaim(tokenId);
        address weth = LibGovernanceStorage.layout().immutableConfiguration.weth;
        LibAssetTransfer.pushExact(weth, receiver, amount);
        emit ICrottoRewards.NFTRewardClaimed(tokenId, weth, receiver, amount);
    }

    function claimNFTTokenReward(uint256 tokenId, address receiver) external nonReentrant returns (uint256 amount) {
        _validateClaim(tokenId, receiver);
        amount = LibRewardAccounting.consumeTokenClaim(tokenId);
        address token = LibGovernanceStorage.layout().immutableConfiguration.activationToken;
        LibAssetTransfer.pushExact(token, receiver, amount);
        emit ICrottoRewards.NFTRewardClaimed(tokenId, token, receiver, amount);
    }

    function onRewardNFTTransfer(address from, address to, uint256 tokenId)
        external
        onlyRewardNFTTransferCallback(from, to, tokenId)
    {
        uint256 removedWeight = _setNftRewardWeight(tokenId, 0, 0);
        emit ICrottoRewards.NFTActivationReset(tokenId, from, to, removedWeight);
    }

    function _validateClaim(uint256 tokenId, address receiver) private view {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidRewardReceiver(receiver);
        IRewardNFT rewardNft = IRewardNFT(governance.immutableConfiguration.rewardNFT);
        address owner = rewardNft.ownerOf(tokenId);
        if (owner != msg.sender) revert NotRewardNFTOwner(tokenId, msg.sender, owner);
    }
}
