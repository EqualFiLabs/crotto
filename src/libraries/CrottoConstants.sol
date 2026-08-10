// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

/// @notice Shared precision, initial economics, and bounded guardian action flags.
library CrottoConstants {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant GENESIS_TREASURY_SUPPLY = 10_000_000 ether;

    uint16 internal constant INITIAL_LOTTERY_WINNER_SHARE_BPS = 5_000;
    uint16 internal constant INITIAL_LOTTERY_NFT_SHARE_BPS = 3_000;
    uint16 internal constant INITIAL_LOTTERY_BUYBACK_SHARE_BPS = 1_000;
    uint16 internal constant INITIAL_LOTTERY_TREASURY_SHARE_BPS = 1_000;

    uint16 internal constant INITIAL_ACTIVATION_BURN_SHARE_BPS = 2_500;
    uint16 internal constant INITIAL_ACTIVATION_NFT_SHARE_BPS = 2_500;
    uint16 internal constant INITIAL_ACTIVATION_TREASURY_SHARE_BPS = 5_000;

    uint16 internal constant INITIAL_HOOK_INPUT_FEE_BPS = 50;
    uint16 internal constant INITIAL_HOOK_OUTPUT_FEE_BPS = 50;
    uint16 internal constant INITIAL_HOOK_POL_SHARE_BPS = 5_000;
    uint16 internal constant INITIAL_HOOK_NFT_SHARE_BPS = 4_000;
    uint16 internal constant INITIAL_HOOK_TREASURY_SHARE_BPS = 1_000;

    uint16 internal constant INITIAL_BUYBACK_SLIPPAGE_BPS = 500;

    uint256 internal constant PAUSE_TICKET_PURCHASES = 1 << 0;
    uint256 internal constant PAUSE_NFT_ACTIVATIONS = 1 << 1;
    uint256 internal constant PAUSE_VAULT_PURCHASES = 1 << 2;
    uint256 internal constant ALL_PAUSE_FLAGS = (1 << 3) - 1;
}
