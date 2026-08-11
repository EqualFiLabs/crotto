// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ICrotto} from "../interfaces/ICrotto.sol";
import {LibBuilderFeesStorage} from "./storage/LibBuilderFeesStorage.sol";
import {LibTreasuryStorage} from "./storage/LibTreasuryStorage.sol";
import {CallerAction} from "../types/CrottoTypes.sol";

/// @notice Internal native Operations Reserve spending and one-use caller-credit accounting.
library LibOperationsAccounting {
    error InvalidRequestCallerAction(CallerAction action);
    error InsufficientOperationsReserve(uint256 available, uint256 required);
    error CallerRewardAlreadyCredited(bytes32 creditKey);
    error NativeAccountingInsolvent(uint256 balance, uint256 required);

    function debitRequestAndCredit(
        address caller,
        CallerAction action,
        uint256 roundId,
        uint32 attempt,
        uint256 requestCost,
        uint256 callerReward,
        uint256 finalizationReserve
    ) internal returns (bytes32 creditKey) {
        if (action != CallerAction.RandomnessRequest && action != CallerAction.RandomnessRetry) {
            revert InvalidRequestCallerAction(action);
        }

        uint256 reserveDebit = requestCost + callerReward;
        uint256 requiredReserve = reserveDebit + finalizationReserve;
        LibTreasuryStorage.Layout storage state = LibTreasuryStorage.layout();
        uint256 available = state.operationsReserveEth;
        if (available < requiredReserve) revert InsufficientOperationsReserve(available, requiredReserve);

        creditKey = keccak256(abi.encode(action, roundId, attempt));
        _consumeCreditKey(state, creditKey);
        state.operationsReserveEth = available - reserveDebit;
        _increaseCallerCredit(state, caller, callerReward);

        emit ICrotto.CallerRewardCredited(caller, action, roundId, callerReward);
    }

    function creditFinalization(address caller, uint256 roundId, uint256 callerReward)
        internal
        returns (bytes32 creditKey)
    {
        LibTreasuryStorage.Layout storage state = LibTreasuryStorage.layout();
        uint256 available = state.operationsReserveEth;
        if (available < callerReward) revert InsufficientOperationsReserve(available, callerReward);

        creditKey = keccak256(abi.encode(CallerAction.Finalization, roundId));
        _consumeCreditKey(state, creditKey);
        state.operationsReserveEth = available - callerReward;
        _increaseCallerCredit(state, caller, callerReward);

        emit ICrotto.CallerRewardCredited(caller, CallerAction.Finalization, roundId, callerReward);
    }

    function creditExpiration(address caller, uint256 roundId, uint256 callerReward)
        internal
        returns (bytes32 creditKey)
    {
        LibTreasuryStorage.Layout storage state = LibTreasuryStorage.layout();
        uint256 available = state.operationsReserveEth;
        if (available < callerReward) revert InsufficientOperationsReserve(available, callerReward);

        creditKey = keccak256(abi.encode(CallerAction.Expiration, roundId));
        _consumeCreditKey(state, creditKey);
        state.operationsReserveEth = available - callerReward;
        _increaseCallerCredit(state, caller, callerReward);

        emit ICrotto.CallerRewardCredited(caller, CallerAction.Expiration, roundId, callerReward);
    }

    function enforceNativeSolvency() internal view {
        LibTreasuryStorage.Layout storage state = LibTreasuryStorage.layout();
        uint256 required = state.operationsReserveEth + state.totalCallerCreditsEth
            + LibBuilderFeesStorage.layout().totalNativeEthLiability;
        uint256 balance = address(this).balance;
        if (balance < required) revert NativeAccountingInsolvent(balance, required);
    }

    function _consumeCreditKey(LibTreasuryStorage.Layout storage state, bytes32 creditKey) private {
        if (state.callerRewardCredited[creditKey]) revert CallerRewardAlreadyCredited(creditKey);
        state.callerRewardCredited[creditKey] = true;
    }

    function _increaseCallerCredit(LibTreasuryStorage.Layout storage state, address caller, uint256 amount) private {
        state.callerCreditsEth[caller] += amount;
        state.totalCallerCreditsEth += amount;
    }
}
