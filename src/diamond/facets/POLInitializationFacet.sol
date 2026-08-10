// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ICrottoSwapFeeHook} from "../../interfaces/ICrottoSwapFeeHook.sol";
import {IPOLInitialization} from "../../interfaces/IPOLInitialization.sol";
import {LibAssetTransfer} from "../../libraries/LibAssetTransfer.sol";
import {LibCanonicalPool} from "../../libraries/LibCanonicalPool.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibPOLStorage} from "../../libraries/storage/LibPOLStorage.sol";
import {ImmutableConfiguration, POLAccountingView} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Permissionless one-time conversion of Bootstrap POL WETH into canonical permanent liquidity.
contract POLInitializationFacet is CrottoFacet, IPOLInitialization {
    using PoolIdLibrary for PoolKey;

    error POLAlreadyInitialized();
    error InsufficientBootstrapWeth(uint256 available, uint256 required);
    error UnexpectedCanonicalPool(PoolId expected, PoolId actual);
    error EmptyInitialLiquidity();

    function initializePOL() external nonReentrant returns (PoolId poolId, uint128 liquidity) {
        LibPOLStorage.Layout storage pol = LibPOLStorage.layout();
        if (pol.initialized) revert POLAlreadyInitialized();

        ImmutableConfiguration memory config = LibGovernanceStorage.layout().immutableConfiguration;
        uint256 bootstrapWeth = pol.bootstrapWeth;
        uint256 requiredWeth = config.requiredBootstrapWeth;
        if (bootstrapWeth < requiredWeth) revert InsufficientBootstrapWeth(bootstrapWeth, requiredWeth);

        uint256 tokenAmount = LibCanonicalPool.bootstrapTokenAmount(requiredWeth, config.initialTokenPerWethWad);
        PoolKey memory poolKey = LibCanonicalPool.key(
            config.activationToken, config.weth, config.canonicalHook, config.canonicalTickSpacing
        );
        uint160 sqrtPrice =
            LibCanonicalPool.sqrtPriceX96(config.activationToken, config.weth, config.initialTokenPerWethWad);
        PoolId expectedPoolId = poolKey.toId();

        // The entire bootstrap class leaves Diamond custody. Only `requiredWeth` determines the mint;
        // threshold excess is passed as unmatched WETH and remains hook-owned POL Pending.
        pol.bootstrapWeth = 0;
        pol.initializationAuthorized = true;
        LibAssetTransfer.pushExact(config.weth, config.canonicalHook, bootstrapWeth);
        (poolId, liquidity) = ICrottoSwapFeeHook(config.canonicalHook)
            .initializeCanonicalPool(poolKey, sqrtPrice, tokenAmount, bootstrapWeth);

        if (PoolId.unwrap(poolId) != PoolId.unwrap(expectedPoolId)) {
            revert UnexpectedCanonicalPool(expectedPoolId, poolId);
        }
        if (liquidity == 0) revert EmptyInitialLiquidity();

        pol.canonicalPoolId = poolId;
        pol.initialized = true;
        pol.initializationAuthorized = false;
        emit POLInitialized(msg.sender, poolId, bootstrapWeth, tokenAmount, liquidity);
    }

    function canInitializePOL() external view returns (bool) {
        LibPOLStorage.Layout storage pol = LibPOLStorage.layout();
        uint256 requiredWeth = LibGovernanceStorage.layout().immutableConfiguration.requiredBootstrapWeth;
        return !pol.initialized && requiredWeth != 0 && pol.bootstrapWeth >= requiredWeth;
    }

    function polInitialized() external view returns (bool) {
        return LibPOLStorage.layout().initialized;
    }

    function polInitializationAuthorized() external view returns (bool) {
        return LibPOLStorage.layout().initializationAuthorized;
    }

    function bootstrapPolWeth() external view returns (uint256) {
        return LibPOLStorage.layout().bootstrapWeth;
    }

    function requiredBootstrapWeth() external view returns (uint256) {
        return LibGovernanceStorage.layout().immutableConfiguration.requiredBootstrapWeth;
    }

    function bootstrapTokenMintAmount() external view returns (uint256) {
        ImmutableConfiguration storage config = LibGovernanceStorage.layout().immutableConfiguration;
        return LibCanonicalPool.bootstrapTokenAmount(config.requiredBootstrapWeth, config.initialTokenPerWethWad);
    }

    function initialTokenPerWethWad() external view returns (uint256) {
        return LibGovernanceStorage.layout().immutableConfiguration.initialTokenPerWethWad;
    }

    function canonicalPoolId() external view returns (PoolId) {
        return LibPOLStorage.layout().canonicalPoolId;
    }

    function polAccounting() external view returns (POLAccountingView memory accounting) {
        LibPOLStorage.Layout storage pol = LibPOLStorage.layout();
        accounting.initialized = pol.initialized;
        accounting.poolId = pol.canonicalPoolId;
        if (!pol.initialized) return accounting;

        ImmutableConfiguration storage config = LibGovernanceStorage.layout().immutableConfiguration;
        ICrottoSwapFeeHook hook = ICrottoSwapFeeHook(config.canonicalHook);
        accounting.lockedLiquidity = hook.lockedLiquidity();
        accounting.pendingToken = hook.pendingPermanentLiquidity(Currency.wrap(config.activationToken));
        accounting.pendingWeth = hook.pendingPermanentLiquidity(Currency.wrap(config.weth));
    }
}
