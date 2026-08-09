// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ActivationConfiguration, HookConfiguration, RoundConfiguration} from "../types/CrottoTypes.sol";

/// @notice Timelock-governed economics, treasury, and bounded guardian controls.
interface ICrottoGovernance {
    event RoundConfigurationSet(RoundConfiguration configuration);
    event ActivationConfigurationSet(uint64 indexed version, ActivationConfiguration configuration);
    event HookConfigurationSet(HookConfiguration configuration);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event ActionsPaused(uint256 indexed flags, address indexed guardian);
    event ActionsUnpaused(uint256 indexed flags);
    event TreasuryWithdrawn(address indexed asset, address indexed receiver, uint256 amount);

    function setRoundConfiguration(RoundConfiguration calldata configuration) external;

    function setActivationConfiguration(ActivationConfiguration calldata configuration) external;

    function setHookConfiguration(HookConfiguration calldata configuration) external;

    function setTreasury(address newTreasury) external;

    function setGuardian(address newGuardian) external;

    function pauseActions(uint256 flags) external;

    function unpauseActions(uint256 flags) external;

    function withdrawTreasuryWeth(address receiver, uint256 amount) external;

    function withdrawTreasuryToken(address receiver, uint256 amount) external;

    function treasury() external view returns (address);

    function guardian() external view returns (address);

    function pausedActions() external view returns (uint256);
}
