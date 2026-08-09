// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookConfiguration} from "../types/CrottoTypes.sol";

/// @notice Narrow canonical hook control and permanent-liquidity accounting surface.
interface ICrottoSwapFeeHook {
    event CanonicalPoolInitialized(
        PoolId indexed poolId, uint160 sqrtPriceX96, uint256 tokenAmount, uint256 wethAmount, uint128 liquidity
    );
    event HookConfigurationSet(HookConfiguration configuration);
    event SwapLegFeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        bool indexed inputLeg,
        uint256 feeAmount,
        uint256 polAmount,
        uint256 nftAmount,
        uint256 treasuryAmount
    );
    event PermanentLiquidityAdded(PoolId indexed poolId, uint128 liquidityAdded, uint256 tokenUsed, uint256 wethUsed);
    event PermanentLiquidityFeesCollected(PoolId indexed poolId, uint256 tokenAmount, uint256 wethAmount);
    event POLDonated(address indexed donor, uint256 tokenAmount, uint256 wethAmount);

    function setHookConfiguration(HookConfiguration calldata configuration) external;

    function initializeCanonicalPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint256 tokenAmount,
        uint256 wethAmount
    ) external returns (PoolId poolId, uint128 liquidity);

    function donatePOL(uint256 tokenAmount, uint256 wethAmount) external returns (uint128 liquidityAdded);

    function compoundPOL() external returns (uint128 liquidityAdded);

    function crottoDiamond() external view returns (address);

    function activationToken() external view returns (address);

    function weth() external view returns (address);

    function canonicalPoolKey() external view returns (PoolKey memory);

    function canonicalPoolId() external view returns (PoolId);

    function hookConfiguration() external view returns (HookConfiguration memory);

    function pendingPermanentLiquidity(Currency currency) external view returns (uint256);

    function lockedLiquidity() external view returns (uint128);

    function poolInitialized() external view returns (bool);
}
