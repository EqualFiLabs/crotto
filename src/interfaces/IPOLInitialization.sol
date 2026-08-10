// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {POLAccountingView} from "../types/CrottoTypes.sol";

/// @notice Permissionless one-time canonical POL bootstrap surface on the Crotto Diamond.
interface IPOLInitialization {
    event POLInitialized(
        address indexed caller, PoolId indexed poolId, uint256 bootstrapWeth, uint256 bootstrapToken, uint128 liquidity
    );

    function initializePOL() external returns (PoolId poolId, uint128 liquidity);

    function canInitializePOL() external view returns (bool);

    function polInitialized() external view returns (bool);

    function polInitializationAuthorized() external view returns (bool);

    function bootstrapPolWeth() external view returns (uint256);

    function requiredBootstrapWeth() external view returns (uint256);

    function bootstrapTokenMintAmount() external view returns (uint256);

    function initialTokenPerWethWad() external view returns (uint256);

    function canonicalPoolId() external view returns (PoolId);

    function polAccounting() external view returns (POLAccountingView memory);
}
