// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CrottoConstants} from "./CrottoConstants.sol";

/// @notice Full-precision gross-budget math with unrestricted direction-aware v4 limits.
library LibAutomaticBuybackMath {
    error ZeroSpecifiedWethInput(uint256 grossBudget, uint16 inputFeeBps);

    struct Quote {
        uint256 specifiedWethIn;
        uint256 inputHookFee;
        uint256 totalWethDebit;
        uint160 sqrtPriceLimitX96;
    }

    function quote(uint256 grossBudget, uint16 inputFeeBps, bool wethIsCurrency0)
        internal
        pure
        returns (Quote memory result)
    {
        result.specifiedWethIn = grossBudget;
        if (result.specifiedWethIn == 0) revert ZeroSpecifiedWethInput(grossBudget, inputFeeBps);
        result.inputHookFee = Math.mulDiv(result.specifiedWethIn, inputFeeBps, CrottoConstants.BPS, Math.Rounding.Ceil);
        if (result.inputHookFee >= result.specifiedWethIn) {
            revert ZeroSpecifiedWethInput(grossBudget, inputFeeBps);
        }
        result.totalWethDebit = result.specifiedWethIn;
        result.sqrtPriceLimitX96 = wethIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}
