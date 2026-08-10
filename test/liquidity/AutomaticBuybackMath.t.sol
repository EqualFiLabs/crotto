// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LibAutomaticBuybackMath} from "../../src/libraries/LibAutomaticBuybackMath.sol";

contract AutomaticBuybackMathHarness {
    function quote(
        uint256 grossBudget,
        uint16 inputFeeBps,
        uint16 outputFeeBps,
        uint16 slippageBps,
        uint160 sqrtPriceX96,
        bool wethIsCurrency0
    ) external pure returns (LibAutomaticBuybackMath.Quote memory) {
        return LibAutomaticBuybackMath.quote(
            grossBudget, inputFeeBps, outputFeeBps, slippageBps, sqrtPriceX96, wethIsCurrency0
        );
    }

    function sqrtPriceLimit(uint160 currentSqrtPriceX96, uint16 slippageBps, bool zeroForOne)
        external
        pure
        returns (uint160)
    {
        return LibAutomaticBuybackMath.sqrtPriceLimit(currentSqrtPriceX96, slippageBps, zeroForOne);
    }
}

contract AutomaticBuybackMathTest is Test {
    AutomaticBuybackMathHarness private harness = new AutomaticBuybackMathHarness();

    function testFuzz_GrossBudgetIsFullyDebitedAndFeesStayInsideIt(uint128 grossSeed, uint16 feeSeed) public view {
        uint256 grossBudget = bound(uint256(grossSeed), 10_001, type(uint128).max);
        uint16 inputFeeBps = uint16(bound(uint256(feeSeed), 0, 100));
        LibAutomaticBuybackMath.Quote memory result =
            harness.quote(grossBudget, inputFeeBps, 50, 500, TickMath.getSqrtPriceAtTick(0), true);

        assertEq(result.specifiedWethIn, grossBudget);
        assertEq(result.totalWethDebit, grossBudget);
        assertLt(result.inputHookFee, grossBudget);
        assertGt(result.spotNetTokenOut, result.minimumNetTokenOut);
    }

    function test_DirectionalLimitsProtectBothCurrencyOrders() public view {
        uint160 current = TickMath.getSqrtPriceAtTick(0);
        LibAutomaticBuybackMath.Quote memory wethCurrency0 = harness.quote(1 ether, 50, 50, 500, current, true);
        LibAutomaticBuybackMath.Quote memory wethCurrency1 = harness.quote(1 ether, 50, 50, 500, current, false);

        assertLt(wethCurrency0.sqrtPriceLimitX96, current);
        assertGt(wethCurrency1.sqrtPriceLimitX96, current);
        assertEq(wethCurrency0.minimumNetTokenOut, wethCurrency1.minimumNetTokenOut);
    }

    function test_RevertWhen_NoValidDirectionalPriceLimitRemains() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LibAutomaticBuybackMath.PriceLimitUnavailable.selector,
                uint160(uint256(TickMath.MIN_SQRT_PRICE) + 1),
                true
            )
        );
        harness.sqrtPriceLimit(uint160(uint256(TickMath.MIN_SQRT_PRICE) + 1), 500, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibAutomaticBuybackMath.PriceLimitUnavailable.selector,
                uint160(uint256(TickMath.MAX_SQRT_PRICE) - 1),
                false
            )
        );
        harness.sqrtPriceLimit(uint160(uint256(TickMath.MAX_SQRT_PRICE) - 1), 500, false);
    }
}
