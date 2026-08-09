// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IActivationToken} from "../interfaces/IActivationToken.sol";
import {CrottoConstants} from "../libraries/CrottoConstants.sol";

/// @notice Crotto's restricted-supply ERC-20 used for player rewards, activation, and permanent liquidity.
contract ActivationToken is ERC20, IActivationToken {
    uint256 public constant override GENESIS_TREASURY_SUPPLY = CrottoConstants.GENESIS_TREASURY_SUPPLY;

    address private immutable CROTTO_DIAMOND;
    address private immutable CANONICAL_HOOK;

    bool public override bootstrapMintExecuted;

    constructor(address initialTreasuryReceiver, address crottoDiamond_, address canonicalHook_)
        ERC20("Crotto", "CROTTO")
    {
        if (initialTreasuryReceiver == address(0) || crottoDiamond_ == address(0) || canonicalHook_ == address(0)) {
            revert ZeroAddress();
        }

        CROTTO_DIAMOND = crottoDiamond_;
        CANONICAL_HOOK = canonicalHook_;

        _mint(initialTreasuryReceiver, GENESIS_TREASURY_SUPPLY);
        emit GenesisTreasuryMinted(initialTreasuryReceiver, GENESIS_TREASURY_SUPPLY);
    }

    /// @inheritdoc IActivationToken
    function mintPlayerReward(address receiver, uint256 amount) external override {
        if (msg.sender != CROTTO_DIAMOND) revert UnauthorizedPlayerMinter(msg.sender);
        _validateMint(receiver, amount);

        _mint(receiver, amount);
        emit PlayerRewardMinted(receiver, amount);
    }

    /// @inheritdoc IActivationToken
    function mintBootstrapPOL(address receiver, uint256 amount) external override {
        if (msg.sender != CANONICAL_HOOK) revert UnauthorizedBootstrapMinter(msg.sender);
        if (bootstrapMintExecuted) revert BootstrapMintAlreadyExecuted();
        _validateMint(receiver, amount);

        bootstrapMintExecuted = true;
        _mint(receiver, amount);
        emit BootstrapPOLMinted(receiver, amount);
    }

    /// @inheritdoc IActivationToken
    function burn(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
    }

    /// @inheritdoc IActivationToken
    function crottoDiamond() external view override returns (address) {
        return CROTTO_DIAMOND;
    }

    /// @inheritdoc IActivationToken
    function canonicalHook() external view override returns (address) {
        return CANONICAL_HOOK;
    }

    function _validateMint(address receiver, uint256 amount) private pure {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
    }
}
