// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LibAutomaticBuybackMath} from "../../src/libraries/LibAutomaticBuybackMath.sol";

contract AutomaticBuybackMathHarness {
    function quote(uint256 grossBudget, uint16 inputFeeBps, bool wethIsCurrency0)
        external
        pure
        returns (LibAutomaticBuybackMath.Quote memory)
    {
        return LibAutomaticBuybackMath.quote(grossBudget, inputFeeBps, wethIsCurrency0);
    }
}

contract AutomaticBuybackMathTest is Test {
    AutomaticBuybackMathHarness private harness = new AutomaticBuybackMathHarness();

    function testFuzz_GrossBudgetIsFullyDebitedAndFeesStayInsideIt(uint128 grossSeed, uint16 feeSeed) public view {
        uint256 grossBudget = bound(uint256(grossSeed), 10_001, type(uint128).max);
        uint16 inputFeeBps = uint16(bound(uint256(feeSeed), 0, 100));
        LibAutomaticBuybackMath.Quote memory result = harness.quote(grossBudget, inputFeeBps, true);

        assertEq(result.specifiedWethIn, grossBudget);
        assertEq(result.totalWethDebit, grossBudget);
        assertLt(result.inputHookFee, grossBudget);
    }

    function test_DirectionalLimitsPermitFullRangeExecutionForBothCurrencyOrders() public view {
        LibAutomaticBuybackMath.Quote memory wethCurrency0 = harness.quote(1 ether, 50, true);
        LibAutomaticBuybackMath.Quote memory wethCurrency1 = harness.quote(1 ether, 50, false);

        assertEq(wethCurrency0.sqrtPriceLimitX96, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(wethCurrency1.sqrtPriceLimitX96, TickMath.MAX_SQRT_PRICE - 1);
    }

    function test_FeeCeilingRejectsBudgetsThatLeaveNoPoolInput() public {
        vm.expectRevert(
            abi.encodeWithSelector(LibAutomaticBuybackMath.ZeroSpecifiedWethInput.selector, uint256(1), uint16(100))
        );
        harness.quote(1, 100, true);
    }
}
