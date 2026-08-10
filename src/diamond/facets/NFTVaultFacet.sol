// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INFTVault} from "../../interfaces/INFTVault.sol";
import {IRewardNFT} from "../../interfaces/IRewardNFT.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibRewardAccounting} from "../../libraries/LibRewardAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibRewardsStorage} from "../../libraries/storage/LibRewardsStorage.sol";
import {LibVaultStorage} from "../../libraries/storage/LibVaultStorage.sol";
import {VaultAccountingView} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Lazy-mint and inventory exchange for fixed-price Reward NFTs.
contract NFTVaultFacet is CrottoFacet, INFTVault {
    error InvalidVaultReceiver(address receiver);
    error RewardNFTMintingComplete(uint256 maximumSupply);
    error RewardNFTMintingIncomplete(uint256 mintedSupply, uint256 maximumSupply);
    error VaultInventoryEmpty();
    error RewardNFTNotInVault(uint256 tokenId);
    error NotRewardNFTOwner(uint256 tokenId, address caller, address owner);
    error InsufficientVaultBacking(uint256 available, uint256 required);
    error VaultBackingInvariant(uint256 available, uint256 required);
    error VaultTokenCustodyInsolvent(uint256 available, uint256 required);
    error MintedTokenIdMismatch(uint256 expected, uint256 actual);

    function buyNewRewardNFT(address receiver)
        external
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_VAULT_PURCHASES)
        returns (uint256 tokenId)
    {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        _validateReceiver(receiver, governance);

        IRewardNFT rewardNft = IRewardNFT(governance.immutableConfiguration.rewardNFT);
        uint256 minted = rewardNft.mintedSupply();
        uint256 maximumSupply = governance.immutableConfiguration.rewardNFTMaxSupply;
        if (minted == maximumSupply) revert RewardNFTMintingComplete(maximumSupply);

        uint256 price = governance.immutableConfiguration.vaultPrice;
        LibAssetTransfer.pullExact(governance.immutableConfiguration.activationToken, msg.sender, price);
        LibVaultStorage.layout().tokenBacking += price;

        tokenId = minted + 1;
        _checkpointNftRewards(tokenId);
        uint256 mintedTokenId = rewardNft.mint(receiver);
        if (mintedTokenId != tokenId) revert MintedTokenIdMismatch(tokenId, mintedTokenId);

        _enforceVaultSolvency(governance, rewardNft);
        emit RewardNFTMinted(tokenId, receiver);
        emit VaultNFTPurchased(msg.sender, receiver, tokenId, price);
    }

    function buyInventoryRewardNFT(uint256 tokenId, address receiver)
        external
        nonReentrant
        whenNotPaused(CrottoConstants.PAUSE_VAULT_PURCHASES)
    {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        _validateReceiver(receiver, governance);

        IRewardNFT rewardNft = IRewardNFT(governance.immutableConfiguration.rewardNFT);
        uint256 minted = rewardNft.mintedSupply();
        uint256 maximumSupply = governance.immutableConfiguration.rewardNFTMaxSupply;
        if (minted != maximumSupply) revert RewardNFTMintingIncomplete(minted, maximumSupply);
        if (rewardNft.balanceOf(address(this)) == 0) revert VaultInventoryEmpty();
        if (!_isVaultInventory(rewardNft, tokenId)) revert RewardNFTNotInVault(tokenId);

        uint256 price = governance.immutableConfiguration.vaultPrice;
        LibAssetTransfer.pullExact(governance.immutableConfiguration.activationToken, msg.sender, price);
        LibVaultStorage.layout().tokenBacking += price;

        _safeTransferRewardNft(rewardNft, address(this), receiver, tokenId);
        _enforceVaultSolvency(governance, rewardNft);
        emit VaultNFTPurchased(msg.sender, receiver, tokenId, price);
    }

    function redeemRewardNFT(uint256 tokenId, address receiver) external nonReentrant {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        _validateReceiver(receiver, governance);

        IRewardNFT rewardNft = IRewardNFT(governance.immutableConfiguration.rewardNFT);
        address owner = rewardNft.ownerOf(tokenId);
        if (owner != msg.sender) revert NotRewardNFTOwner(tokenId, msg.sender, owner);

        uint256 price = governance.immutableConfiguration.vaultPrice;
        LibVaultStorage.Layout storage vault = LibVaultStorage.layout();
        if (vault.tokenBacking < price) revert InsufficientVaultBacking(vault.tokenBacking, price);

        _transferRewardNft(rewardNft, msg.sender, address(this), tokenId);
        vault.tokenBacking -= price;
        LibAssetTransfer.pushExact(governance.immutableConfiguration.activationToken, receiver, price);

        _enforceVaultSolvency(governance, rewardNft);
        emit VaultNFTRedeemed(msg.sender, receiver, tokenId, price);
    }

    function vaultPrice() external view returns (uint256) {
        return LibGovernanceStorage.layout().immutableConfiguration.vaultPrice;
    }

    function vaultInventory() public view returns (uint256) {
        IRewardNFT rewardNft = _rewardNft();
        return rewardNft.balanceOf(address(this));
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function circulatingNFTs() public view returns (uint256) {
        IRewardNFT rewardNft = _rewardNft();
        return rewardNft.mintedSupply() - rewardNft.balanceOf(address(this));
    }

    function requiredVaultBacking() public view returns (uint256) {
        return circulatingNFTs() * LibGovernanceStorage.layout().immutableConfiguration.vaultPrice;
    }

    function isVaultInventory(uint256 tokenId) external view returns (bool) {
        return _isVaultInventory(_rewardNft(), tokenId);
    }

    function vaultAccounting() external view returns (VaultAccountingView memory accounting) {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        IRewardNFT rewardNft = IRewardNFT(governance.immutableConfiguration.rewardNFT);
        uint256 minted = rewardNft.mintedSupply();
        uint256 inventory = rewardNft.balanceOf(address(this));
        uint256 circulating = minted - inventory;
        uint256 price = governance.immutableConfiguration.vaultPrice;
        accounting = VaultAccountingView({
            vaultPrice: price,
            maxSupply: governance.immutableConfiguration.rewardNFTMaxSupply,
            mintedSupply: minted,
            vaultInventory: inventory,
            circulatingNfts: circulating,
            vaultTokenBacking: LibVaultStorage.layout().tokenBacking,
            requiredTokenBacking: circulating * price
        });
    }

    function _validateReceiver(address receiver, LibGovernanceStorage.Layout storage governance) private view {
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidVaultReceiver(receiver);
    }

    function _rewardNft() private view returns (IRewardNFT) {
        return IRewardNFT(LibGovernanceStorage.layout().immutableConfiguration.rewardNFT);
    }

    function _isVaultInventory(IRewardNFT rewardNft, uint256 tokenId) private view returns (bool) {
        try rewardNft.ownerOf(tokenId) returns (address owner) {
            return owner == address(this);
        } catch {
            return false;
        }
    }

    function _transferRewardNft(IRewardNFT rewardNft, address from, address to, uint256 tokenId) private {
        _beginRewardNFTTransfer(from, to, tokenId);
        rewardNft.transferFrom(from, to, tokenId);
        _finishRewardNFTTransfer();
    }

    function _safeTransferRewardNft(IRewardNFT rewardNft, address from, address to, uint256 tokenId) private {
        _beginRewardNFTTransfer(from, to, tokenId);
        rewardNft.safeTransferFrom(from, to, tokenId);
        _finishRewardNFTTransfer();
    }

    function _enforceVaultSolvency(LibGovernanceStorage.Layout storage governance, IRewardNFT rewardNft) private view {
        uint256 minted = rewardNft.mintedSupply();
        uint256 inventory = rewardNft.balanceOf(address(this));
        uint256 requiredBacking = (minted - inventory) * governance.immutableConfiguration.vaultPrice;
        uint256 tokenBacking = LibVaultStorage.layout().tokenBacking;
        if (tokenBacking < requiredBacking) revert VaultBackingInvariant(tokenBacking, requiredBacking);

        uint256 rewardLiability = LibRewardAccounting.outstanding(LibRewardsStorage.layout().tokenBook);
        uint256 requiredCustody = tokenBacking + rewardLiability;
        uint256 custody = IERC20(governance.immutableConfiguration.activationToken).balanceOf(address(this));
        if (custody < requiredCustody) revert VaultTokenCustodyInsolvent(custody, requiredCustody);
    }
}
