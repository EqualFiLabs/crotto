// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICrottoRewards} from "../interfaces/ICrottoRewards.sol";
import {IRewardNFT} from "../interfaces/IRewardNFT.sol";

/// @notice Fixed-maximum-supply Crottos collection with Diamond-only sequential minting.
contract RewardNFT is ERC721, IRewardNFT {
    address private immutable CROTTO_DIAMOND;
    uint256 private immutable MAX_SUPPLY;

    uint256 public override mintedSupply;

    constructor(address crottoDiamond_, uint256 maxSupply_) ERC721("Crottos", "CROTTOS") {
        if (crottoDiamond_ == address(0)) revert ZeroAddress();
        if (maxSupply_ == 0) revert InvalidMaxSupply();

        CROTTO_DIAMOND = crottoDiamond_;
        MAX_SUPPLY = maxSupply_;
    }

    /// @inheritdoc IRewardNFT
    function mint(address receiver) external override returns (uint256 tokenId) {
        if (msg.sender != CROTTO_DIAMOND) revert UnauthorizedMinter(msg.sender);
        if (receiver == address(0)) revert ZeroAddress();

        uint256 currentSupply = mintedSupply;
        if (currentSupply == MAX_SUPPLY) revert MaxSupplyReached(MAX_SUPPLY);

        tokenId = currentSupply + 1;
        mintedSupply = tokenId;
        _safeMint(receiver, tokenId);
    }

    /// @inheritdoc IRewardNFT
    function maxSupply() external view override returns (uint256) {
        return MAX_SUPPLY;
    }

    /// @inheritdoc IRewardNFT
    function crottoDiamond() external view override returns (address) {
        return CROTTO_DIAMOND;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return interfaceId == type(IRewardNFT).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Authenticates first, then requires the Diamond to settle/reset before ownership changes.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from == address(0)) return super._update(to, tokenId, auth);

        if (auth != address(0)) _checkAuthorized(from, auth, tokenId);
        if (CROTTO_DIAMOND.code.length == 0) revert DiamondCallbackUnavailable(CROTTO_DIAMOND);

        ICrottoRewards(CROTTO_DIAMOND).onRewardNFTTransfer(from, to, tokenId);
        super._update(to, tokenId, address(0));
    }
}
