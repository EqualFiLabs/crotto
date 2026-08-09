// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Restricted TOKEN surface: Diamond player emissions, one hook bootstrap mint, and holder burns.
interface IActivationToken is IERC20 {
    event GenesisTreasuryMinted(address indexed treasuryReceiver, uint256 amount);
    event PlayerRewardMinted(address indexed receiver, uint256 amount);
    event BootstrapPOLMinted(address indexed receiver, uint256 amount);

    function GENESIS_TREASURY_SUPPLY() external view returns (uint256);

    function mintPlayerReward(address receiver, uint256 amount) external;

    function mintBootstrapPOL(address receiver, uint256 amount) external;

    function burn(uint256 amount) external;

    function bootstrapMintExecuted() external view returns (bool);

    function crottoDiamond() external view returns (address);

    function canonicalHook() external view returns (address);
}
