// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {VaultAccountingView} from "../types/CrottoTypes.sol";

/// @notice Fixed-price Reward NFT exchange backed by isolated TOKEN custody.
interface INFTVault {
    event RewardNFTMinted(uint256 indexed tokenId, address indexed receiver);
    event VaultNFTPurchased(address indexed buyer, address indexed receiver, uint256 indexed tokenId, uint256 price);
    event VaultNFTRedeemed(address indexed seller, address indexed receiver, uint256 indexed tokenId, uint256 price);

    function buyNewRewardNFT(address receiver) external returns (uint256 tokenId);

    function buyInventoryRewardNFT(uint256 tokenId, address receiver) external;

    function redeemRewardNFT(uint256 tokenId, address receiver) external;

    function vaultPrice() external view returns (uint256);

    function vaultInventory() external view returns (uint256);

    // forge-lint: disable-next-line(mixed-case-function)
    function circulatingNFTs() external view returns (uint256);

    function requiredVaultBacking() external view returns (uint256);

    function isVaultInventory(uint256 tokenId) external view returns (bool);

    function vaultAccounting() external view returns (VaultAccountingView memory);
}
