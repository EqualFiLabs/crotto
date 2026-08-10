// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {
    ActivationConfiguration,
    BuybackConfiguration,
    HookConfiguration,
    RoundConfiguration
} from "../types/CrottoTypes.sol";

/// @notice Timelock-governed economics, external Treasury Receiver, and bounded guardian controls.
interface ICrottoGovernance {
    event RoundConfigurationSet(RoundConfiguration configuration);
    event ActivationConfigurationSet(uint64 indexed version, ActivationConfiguration configuration);
    event HookConfigurationSet(HookConfiguration configuration);
    event BuybackConfigurationSet(BuybackConfiguration configuration);
    event TreasuryReceiverChanged(address indexed previousReceiver, address indexed newReceiver);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event ActionsPaused(uint256 indexed flags, address indexed caller);
    event ActionsUnpaused(uint256 indexed flags);

    function setRoundConfiguration(RoundConfiguration calldata configuration) external;

    function setActivationConfiguration(ActivationConfiguration calldata configuration) external;

    function setHookConfiguration(HookConfiguration calldata configuration) external;

    function setBuybackConfiguration(BuybackConfiguration calldata configuration) external;

    function setTreasuryReceiver(address newReceiver) external;

    function setGuardian(address newGuardian) external;

    function pauseActions(uint256 flags) external;

    function unpauseActions(uint256 flags) external;

    function treasuryReceiver() external view returns (address);

    function guardian() external view returns (address);

    function pausedActions() external view returns (uint256);

    function buybackConfiguration() external view returns (BuybackConfiguration memory);
}
