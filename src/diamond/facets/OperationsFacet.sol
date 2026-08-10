// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ICrotto} from "../../interfaces/ICrotto.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibTreasuryStorage} from "../../libraries/storage/LibTreasuryStorage.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Permissionless Operations Reserve funding and pull-based native caller credits.
contract OperationsFacet is CrottoFacet {
    error ZeroOperationsContribution();
    error InvalidCallerRewardReceiver(address receiver);
    error NativeTransferFailed(address receiver, uint256 amount);
    error UnexpectedNativeDebit(uint256 expected, uint256 actual);

    function fundOperationsReserve() external payable nonReentrant {
        if (msg.value == 0) revert ZeroOperationsContribution();
        LibTreasuryStorage.layout().operationsReserveEth += msg.value;
        LibOperationsAccounting.enforceNativeSolvency();
        emit ICrotto.OperationsReserveFunded(msg.sender, msg.value);
    }

    function claimCallerRewards(address receiver) external nonReentrant returns (uint256 amount) {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidCallerRewardReceiver(receiver);

        LibTreasuryStorage.Layout storage state = LibTreasuryStorage.layout();
        amount = state.callerCreditsEth[msg.sender];
        if (amount != 0) {
            state.callerCreditsEth[msg.sender] = 0;
            state.totalCallerCreditsEth -= amount;

            uint256 balanceBefore = address(this).balance;
            bool success = _sendNative(receiver, amount);
            if (!success) revert NativeTransferFailed(receiver, amount);
            uint256 balanceAfter = address(this).balance;
            uint256 actualDebit = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
            if (actualDebit != amount) revert UnexpectedNativeDebit(amount, actualDebit);
        }

        LibOperationsAccounting.enforceNativeSolvency();
        emit ICrotto.CallerRewardClaimed(msg.sender, receiver, amount);
    }

    function callerCredit(address account) external view returns (uint256) {
        return LibTreasuryStorage.layout().callerCreditsEth[account];
    }

    function operationsReserve() external view returns (uint256) {
        return LibTreasuryStorage.layout().operationsReserveEth;
    }

    function totalCallerCredits() external view returns (uint256) {
        return LibTreasuryStorage.layout().totalCallerCreditsEth;
    }

    /// @dev Ignores return data so a recipient cannot force an unbounded copy into Diamond memory.
    function _sendNative(address receiver, uint256 amount) private returns (bool success) {
        assembly ("memory-safe") {
            success := call(gas(), receiver, amount, 0, 0, 0, 0)
        }
    }
}
