// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/// @notice Fixed-maximum-supply Reward NFT with Diamond-only sequential minting.
interface IRewardNFT is IERC721Metadata {
    error ZeroAddress();
    error InvalidMaxSupply();
    error UnauthorizedMinter(address caller);
    error MaxSupplyReached(uint256 maxSupply);

    function mint(address receiver) external returns (uint256 tokenId);

    function maxSupply() external view returns (uint256);

    function mintedSupply() external view returns (uint256);

    function crottoDiamond() external view returns (address);
}
