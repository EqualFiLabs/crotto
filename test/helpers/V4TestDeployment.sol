// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Isolated 0.8.26 deployment artifact for 0.8.33 Crotto integration tests.
contract V4TestDeployment {
    IPoolManager public immutable manager;
    PoolDonateTest public immutable donateRouter;
    PoolModifyLiquidityTest public immutable modifyLiquidityRouter;
    PoolSwapTest public immutable swapRouter;

    constructor() {
        manager = new PoolManager(address(this));
        donateRouter = new PoolDonateTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
    }
}
