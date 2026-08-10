// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CrottoConstants} from "./CrottoConstants.sol";

/// @notice Full-precision gross-budget and direction-aware spot protection math.
library LibAutomaticBuybackMath {
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant Q192 = 1 << 192;
    uint256 private constant WAD = 1e18;
    uint256 private constant WAD_SQUARED = 1e36;

    error ZeroSpecifiedWethInput(uint256 grossBudget, uint16 inputFeeBps);
    error ZeroNetTokenOutput(uint256 grossTokenOutput, uint16 outputFeeBps);
    error PriceLimitUnavailable(uint160 currentSqrtPriceX96, bool zeroForOne);

    struct Quote {
        uint256 specifiedWethIn;
        uint256 inputHookFee;
        uint256 totalWethDebit;
        uint256 spotNetTokenOut;
        uint256 minimumNetTokenOut;
        uint160 sqrtPriceLimitX96;
    }

    function quote(
        uint256 grossBudget,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 slippageBps,
        uint160 sqrtPriceX96,
        bool wethIsCurrency0
    ) internal pure returns (Quote memory result) {
        result.specifiedWethIn = grossBudget;
        if (result.specifiedWethIn == 0) revert ZeroSpecifiedWethInput(grossBudget, inputFeeBps);
        result.inputHookFee = Math.mulDiv(result.specifiedWethIn, inputFeeBps, CrottoConstants.BPS, Math.Rounding.Ceil);
        if (result.inputHookFee >= result.specifiedWethIn) {
            revert ZeroSpecifiedWethInput(grossBudget, inputFeeBps);
        }
        result.totalWethDebit = result.specifiedWethIn;

        uint256 poolWethInput = result.specifiedWethIn - result.inputHookFee;
        uint256 grossTokenOut = quoteAtSqrtPrice(sqrtPriceX96, poolWethInput, wethIsCurrency0);
        uint256 outputHookFee = Math.mulDiv(grossTokenOut, outputFeeBps, CrottoConstants.BPS, Math.Rounding.Ceil);
        if (grossTokenOut <= outputHookFee) revert ZeroNetTokenOutput(grossTokenOut, outputFeeBps);
        result.spotNetTokenOut = grossTokenOut - outputHookFee;
        result.minimumNetTokenOut =
            Math.mulDiv(result.spotNetTokenOut, CrottoConstants.BPS - slippageBps, CrottoConstants.BPS);
        if (result.minimumNetTokenOut == 0) revert ZeroNetTokenOutput(grossTokenOut, outputFeeBps);
        result.sqrtPriceLimitX96 = sqrtPriceLimit(sqrtPriceX96, slippageBps, wethIsCurrency0);
    }

    function quoteAtSqrtPrice(uint160 sqrtPriceX96, uint256 amountIn, bool inputIsCurrency0)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            amountOut =
                inputIsCurrency0 ? Math.mulDiv(amountIn, ratioX192, Q192) : Math.mulDiv(amountIn, Q192, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            amountOut =
                inputIsCurrency0 ? Math.mulDiv(amountIn, ratioX128, Q128) : Math.mulDiv(amountIn, Q128, ratioX128);
        }
    }

    function sqrtPriceLimit(uint160 currentSqrtPriceX96, uint16 slippageBps, bool zeroForOne)
        internal
        pure
        returns (uint160 limit)
    {
        if (
            (zeroForOne && currentSqrtPriceX96 <= uint256(TickMath.MIN_SQRT_PRICE) + 1)
                || (!zeroForOne && currentSqrtPriceX96 >= uint256(TickMath.MAX_SQRT_PRICE) - 1)
        ) revert PriceLimitUnavailable(currentSqrtPriceX96, zeroForOne);

        uint256 factorSquaredWad = Math.mulDiv(CrottoConstants.BPS - slippageBps, WAD_SQUARED, CrottoConstants.BPS);
        uint256 factorWad = Math.sqrt(factorSquaredWad, Math.Rounding.Ceil);
        uint256 rawLimit = zeroForOne
            ? Math.mulDiv(currentSqrtPriceX96, factorWad, WAD, Math.Rounding.Ceil)
            : Math.mulDiv(currentSqrtPriceX96, WAD, factorWad);

        if (zeroForOne) {
            uint256 minimum = uint256(TickMath.MIN_SQRT_PRICE) + 1;
            if (rawLimit < minimum) rawLimit = minimum;
            if (rawLimit >= currentSqrtPriceX96) rawLimit = uint256(currentSqrtPriceX96) - 1;
        } else {
            uint256 maximum = uint256(TickMath.MAX_SQRT_PRICE) - 1;
            if (rawLimit > maximum) rawLimit = maximum;
            if (rawLimit <= currentSqrtPriceX96) rawLimit = uint256(currentSqrtPriceX96) + 1;
        }
        limit = uint160(rawLimit);
    }
}
