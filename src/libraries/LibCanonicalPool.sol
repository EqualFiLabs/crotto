// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Deterministic canonical TOKEN/WETH pool construction and genesis pricing.
library LibCanonicalPool {
    uint256 internal constant WAD = 1e18;
    uint256 private constant Q192 = 1 << 192;

    error InvalidCanonicalAssets(address activationToken, address weth);
    error InvalidGenesisRatio(uint256 tokenPerWethWad);
    error InvalidGenesisSqrtPrice(uint256 sqrtPriceX96);

    function key(address activationToken, address weth, address hook, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory poolKey)
    {
        if (activationToken == weth) revert InvalidCanonicalAssets(activationToken, weth);
        (Currency currency0, Currency currency1) = activationToken < weth
            ? (Currency.wrap(activationToken), Currency.wrap(weth))
            : (Currency.wrap(weth), Currency.wrap(activationToken));
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 0, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });
    }

    function bootstrapTokenAmount(uint256 requiredWeth, uint256 tokenPerWethWad)
        internal
        pure
        returns (uint256 amount)
    {
        amount = Math.mulDiv(requiredWeth, tokenPerWethWad, WAD);
        if (amount == 0) revert InvalidGenesisRatio(tokenPerWethWad);
    }

    function sqrtPriceX96(address activationToken, address weth, uint256 tokenPerWethWad)
        internal
        pure
        returns (uint160 price)
    {
        if (activationToken == weth) revert InvalidCanonicalAssets(activationToken, weth);
        if (tokenPerWethWad == 0) revert InvalidGenesisRatio(tokenPerWethWad);

        // Uniswap encodes currency1 / currency0. Both canonical assets use 18 decimals.
        uint256 ratioX192 =
            activationToken < weth ? Math.mulDiv(WAD, Q192, tokenPerWethWad) : Math.mulDiv(tokenPerWethWad, Q192, WAD);
        uint256 sqrtRatio = Math.sqrt(ratioX192);
        if (sqrtRatio < TickMath.MIN_SQRT_PRICE || sqrtRatio >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidGenesisSqrtPrice(sqrtRatio);
        }
        price = uint160(sqrtRatio);
    }
}
