// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAutomaticTicketBuyback} from "../interfaces/IAutomaticTicketBuyback.sol";
import {ICrottoSwapFeeHook} from "../interfaces/ICrottoSwapFeeHook.sol";
import {LibAssetTransfer} from "./LibAssetTransfer.sol";
import {LibAutomaticBuybackMath} from "./LibAutomaticBuybackMath.sol";
import {LibCanonicalPool} from "./LibCanonicalPool.sol";
import {LibCrottoGuard} from "./LibCrottoGuard.sol";
import {LibBuybackStorage} from "./storage/LibBuybackStorage.sol";
import {LibGovernanceStorage} from "./storage/LibGovernanceStorage.sol";
import {LibPOLStorage} from "./storage/LibPOLStorage.sol";
import {HookConfiguration, ImmutableConfiguration} from "../types/CrottoTypes.sol";

/// @notice Transaction-scoped canonical PoolManager settlement for automatic ticket buybacks.
library LibAutomaticBuyback {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    bytes32 private constant EXECUTION_CONSUMED = bytes32(uint256(1));

    error CanonicalPOLNotInitialized();
    error BuybackExecutionAlreadyActive();
    error InvalidBuybackExecutionContext();
    error InvalidPoolManagerCaller(address caller, address expected);
    error InvalidCanonicalPool(PoolId expected, PoolId actual);
    error InvalidCanonicalDirection();
    error InvalidTreasuryReceiver(address receiver, address expected);
    error UnexpectedWethDebt(uint256 expected, int256 actual);
    error ZeroTokenOutput();
    error UnexpectedSettlement(uint256 expected, uint256 actual);
    error UnexpectedPoolManagerDebit(address asset, uint256 expected, uint256 actual);
    error UnexpectedTreasuryReceipt(uint256 expected, uint256 actual);
    error UnsettledCurrencyDelta(address asset, int256 delta);

    struct UnlockPayload {
        PoolKey key;
        bool zeroForOne;
        uint256 specifiedWethIn;
        uint160 sqrtPriceLimitX96;
        uint256 expectedWethDebit;
        address treasuryReceiver;
    }

    function execute(address caller, uint256 consumedWeth, uint256 callerTipWeth, uint256 grossWethBudget)
        internal
        returns (LibAutomaticBuybackMath.Quote memory quote, uint256 actualNetTokenOut)
    {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        ImmutableConfiguration memory immutableConfig = governance.immutableConfiguration;
        LibPOLStorage.Layout storage pol = LibPOLStorage.layout();
        if (!pol.initialized) revert CanonicalPOLNotInitialized();

        ICrottoSwapFeeHook hook = ICrottoSwapFeeHook(immutableConfig.canonicalHook);
        PoolKey memory key = hook.canonicalPoolKey();
        PoolId poolId = key.toId();
        if (PoolId.unwrap(poolId) != PoolId.unwrap(pol.canonicalPoolId)) {
            revert InvalidCanonicalPool(pol.canonicalPoolId, poolId);
        }
        PoolKey memory expectedKey = LibCanonicalPool.key(
            immutableConfig.activationToken,
            immutableConfig.weth,
            immutableConfig.canonicalHook,
            immutableConfig.canonicalTickSpacing
        );
        if (PoolId.unwrap(expectedKey.toId()) != PoolId.unwrap(poolId)) {
            revert InvalidCanonicalPool(expectedKey.toId(), poolId);
        }

        bool wethIsCurrency0 = Currency.unwrap(key.currency0) == immutableConfig.weth;
        if (!wethIsCurrency0 && Currency.unwrap(key.currency1) != immutableConfig.weth) {
            revert InvalidCanonicalDirection();
        }
        IPoolManager manager = IPoolManager(immutableConfig.uniswapV4PoolManager);
        HookConfiguration memory hookConfiguration = hook.hookConfiguration();
        quote = LibAutomaticBuybackMath.quote(grossWethBudget, hookConfiguration.inputFeeBps, wethIsCurrency0);

        UnlockPayload memory payload = UnlockPayload({
            key: key,
            zeroForOne: wethIsCurrency0,
            specifiedWethIn: quote.specifiedWethIn,
            sqrtPriceLimitX96: quote.sqrtPriceLimitX96,
            expectedWethDebit: quote.totalWethDebit,
            treasuryReceiver: governance.treasuryReceiver
        });
        bytes memory encodedPayload = abi.encode(payload);
        LibBuybackStorage.Layout storage buyback = LibBuybackStorage.layout();
        if (buyback.activeExecutionHash != bytes32(0)) revert BuybackExecutionAlreadyActive();
        buyback.activeExecutionHash = keccak256(encodedPayload);
        LibCrottoGuard.beginCanonicalHookRevenue(
            immutableConfig.canonicalHook, immutableConfig.weth, immutableConfig.activationToken
        );

        bytes memory result = manager.unlock(encodedPayload);
        if (buyback.activeExecutionHash != EXECUTION_CONSUMED) revert InvalidBuybackExecutionContext();
        delete buyback.activeExecutionHash;
        LibCrottoGuard.finishCanonicalHookRevenue();
        (uint256 actualWethDebit, uint256 tokenOutput) = abi.decode(result, (uint256, uint256));
        if (actualWethDebit != quote.totalWethDebit) {
            revert UnexpectedWethDebt(quote.totalWethDebit, -int256(actualWethDebit));
        }
        actualNetTokenOut = tokenOutput;

        LibBuybackStorage.Layout storage totals = LibBuybackStorage.layout();
        totals.totalWethPurchased += grossWethBudget;
        totals.totalTokenReceived += actualNetTokenOut;
        uint256 sequence = ++totals.executionCount;
        emit IAutomaticTicketBuyback.PendingBuybackExecuted(
            caller,
            payload.treasuryReceiver,
            sequence,
            consumedWeth,
            callerTipWeth,
            quote.specifiedWethIn,
            quote.inputHookFee,
            actualWethDebit,
            actualNetTokenOut
        );
    }

    function unlockCallback(bytes calldata data) internal returns (bytes memory result) {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        ImmutableConfiguration storage immutableConfig = governance.immutableConfiguration;
        address expectedManager = immutableConfig.uniswapV4PoolManager;
        if (msg.sender != expectedManager) revert InvalidPoolManagerCaller(msg.sender, expectedManager);

        LibBuybackStorage.Layout storage buyback = LibBuybackStorage.layout();
        if (buyback.activeExecutionHash == bytes32(0) || buyback.activeExecutionHash != keccak256(data)) {
            revert InvalidBuybackExecutionContext();
        }
        buyback.activeExecutionHash = EXECUTION_CONSUMED;

        UnlockPayload memory payload = abi.decode(data, (UnlockPayload));
        PoolId expectedPoolId = LibPOLStorage.layout().canonicalPoolId;
        PoolId actualPoolId = payload.key.toId();
        if (PoolId.unwrap(actualPoolId) != PoolId.unwrap(expectedPoolId)) {
            revert InvalidCanonicalPool(expectedPoolId, actualPoolId);
        }
        bool wethIsCurrency0 = Currency.unwrap(payload.key.currency0) == immutableConfig.weth;
        if (payload.zeroForOne != wethIsCurrency0) revert InvalidCanonicalDirection();
        if (payload.treasuryReceiver != governance.treasuryReceiver) {
            revert InvalidTreasuryReceiver(payload.treasuryReceiver, governance.treasuryReceiver);
        }

        IPoolManager manager = IPoolManager(expectedManager);
        manager.swap(
            payload.key,
            SwapParams({
                zeroForOne: payload.zeroForOne,
                amountSpecified: -int256(payload.specifiedWethIn),
                sqrtPriceLimitX96: payload.sqrtPriceLimitX96
            }),
            ""
        );

        Currency wethCurrency = Currency.wrap(immutableConfig.weth);
        Currency tokenCurrency = Currency.wrap(immutableConfig.activationToken);
        int256 wethDelta = manager.currencyDelta(address(this), wethCurrency);
        if (wethDelta != -int256(payload.expectedWethDebit)) {
            revert UnexpectedWethDebt(payload.expectedWethDebit, wethDelta);
        }
        int256 tokenDelta = manager.currencyDelta(address(this), tokenCurrency);
        if (tokenDelta <= 0) revert ZeroTokenOutput();
        uint256 tokenOutput = uint256(tokenDelta);

        manager.sync(wethCurrency);
        LibAssetTransfer.pushExact(immutableConfig.weth, expectedManager, payload.expectedWethDebit);
        uint256 settled = manager.settle();
        if (settled != payload.expectedWethDebit) revert UnexpectedSettlement(payload.expectedWethDebit, settled);

        IERC20 token = IERC20(immutableConfig.activationToken);
        uint256 managerBefore = token.balanceOf(expectedManager);
        uint256 receiverBefore = token.balanceOf(payload.treasuryReceiver);
        manager.take(tokenCurrency, payload.treasuryReceiver, tokenOutput);
        uint256 managerAfter = token.balanceOf(expectedManager);
        uint256 receiverAfter = token.balanceOf(payload.treasuryReceiver);
        uint256 managerDebit = managerBefore >= managerAfter ? managerBefore - managerAfter : 0;
        if (managerDebit != tokenOutput) {
            revert UnexpectedPoolManagerDebit(immutableConfig.activationToken, tokenOutput, managerDebit);
        }
        uint256 receiverCredit = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (receiverCredit != tokenOutput) revert UnexpectedTreasuryReceipt(tokenOutput, receiverCredit);

        int256 remainingWethDelta = manager.currencyDelta(address(this), wethCurrency);
        if (remainingWethDelta != 0) revert UnsettledCurrencyDelta(immutableConfig.weth, remainingWethDelta);
        int256 remainingTokenDelta = manager.currencyDelta(address(this), tokenCurrency);
        if (remainingTokenDelta != 0) {
            revert UnsettledCurrencyDelta(immutableConfig.activationToken, remainingTokenDelta);
        }
        result = abi.encode(payload.expectedWethDebit, tokenOutput);
    }
}
