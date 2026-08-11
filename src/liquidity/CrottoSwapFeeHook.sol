// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IActivationToken} from "../interfaces/IActivationToken.sol";
import {ICrottoGovernance} from "../interfaces/ICrottoGovernance.sol";
import {ICrottoRewards} from "../interfaces/ICrottoRewards.sol";
import {ICrottoSwapFeeHook} from "../interfaces/ICrottoSwapFeeHook.sol";
import {IPOLInitialization} from "../interfaces/IPOLInitialization.sol";
import {CrottoConstants} from "../libraries/CrottoConstants.sol";
import {LibAssetTransfer} from "../libraries/LibAssetTransfer.sol";
import {LibCanonicalPool} from "../libraries/LibCanonicalPool.sol";
import {HookConfiguration} from "../types/CrottoTypes.sol";

/// @notice Canonical TOKEN/WETH bilateral-fee hook with permanently locked protocol-owned liquidity.
contract CrottoSwapFeeHook is BaseHook, ICrottoSwapFeeHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    uint8 private constant UNLOCK_COMPOUND = 1;
    bytes32 private constant PERMANENT_LIQUIDITY_SALT = keccak256("crotto.permanent.liquidity");
    uint16 private constant ORACLE_CARDINALITY = 64;
    uint32 private constant ORACLE_CHECKPOINT_PERIOD = 1 minutes;

    struct OracleObservation {
        uint32 timestamp;
        int256 tickCumulative;
    }

    address public immutable override crottoDiamond;
    address public immutable override activationToken;
    address public immutable override weth;
    int24 public immutable override canonicalTickSpacing;
    uint256 public immutable override initialTokenPerWethWad;
    uint16 public immutable override maxCombinedHookFeeBps;

    HookConfiguration private _hookConfiguration;
    PoolKey private _canonicalPoolKey;
    PoolId private _canonicalPoolId;
    mapping(Currency currency => uint256 amount) private _polPending;
    mapping(Currency currency => uint256 amount) private _totalPending;
    uint128 private _lockedLiquidity;
    bool private _poolInitialized;
    bool private _initializationActive;
    bool private _liquidityModificationActive;
    bool private _entered;
    OracleObservation[ORACLE_CARDINALITY] private _observations;
    uint16 private _observationIndex;
    uint16 private _observationCount;
    uint32 private _lastOracleTimestamp;
    int24 private _lastOracleTick;
    int256 private _tickCumulative;

    error ZeroAddress();
    error OnlyCrottoDiamond(address caller);
    error InvalidHookConfiguration();
    error InvalidCanonicalTickSpacing(int24 tickSpacing);
    error CanonicalPoolAlreadyInitialized();
    error CanonicalPoolNotInitialized();
    error InitializationNotAuthorized();
    error InvalidCanonicalPool();
    error InvalidCanonicalPrice(uint160 expected, uint160 actual);
    error UnauthorizedPoolInitialization(address sender);
    error ExternalLiquidityModification(address sender);
    error PermanentLiquidityRemovalForbidden();
    error EmptyPOLDonation();
    error EmptyInitialLiquidity();
    error ReentrantHookCall();
    error InvalidUnlockCaller(address caller);
    error InvalidUnlockAction(uint8 action);
    error UnexpectedBootstrapMint(uint256 expected, uint256 actual);
    error InsufficientBootstrapWeth(uint256 expected, uint256 available);
    error PendingLiquidityInsolvent(Currency currency, uint256 required, uint256 available);
    error PermanentLiquidityExceedsPending(Currency currency, uint256 required, uint256 available);
    error UnexpectedTokenDebit(Currency currency, uint256 expected, uint256 actual);
    error IncompatiblePoolCurrency(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedSettlement(Currency currency, uint256 expected, uint256 actual);
    error UnexpectedTokenAllowance(Currency currency, uint256 remaining);
    error OracleHistoryUnavailable(uint32 secondsAgo);
    error InvalidOraclePeriod();

    modifier onlyDiamond() {
        if (msg.sender != crottoDiamond) revert OnlyCrottoDiamond(msg.sender);
        _;
    }

    modifier nonReentrantHook() {
        if (_entered) revert ReentrantHookCall();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(
        IPoolManager manager,
        address crottoDiamond_,
        address activationToken_,
        address weth_,
        int24 tickSpacing_,
        uint256 tokenPerWethWad_,
        uint16 combinedFeeCeilingBps_
    ) BaseHook(manager) {
        if (crottoDiamond_ == address(0) || activationToken_ == address(0) || weth_ == address(0)) {
            revert ZeroAddress();
        }
        if (tickSpacing_ < TickMath.MIN_TICK_SPACING || tickSpacing_ > TickMath.MAX_TICK_SPACING) {
            revert InvalidCanonicalTickSpacing(tickSpacing_);
        }
        LibCanonicalPool.key(activationToken_, weth_, address(this), tickSpacing_);
        LibCanonicalPool.sqrtPriceX96(activationToken_, weth_, tokenPerWethWad_);
        if (combinedFeeCeilingBps_ == 0 || combinedFeeCeilingBps_ > CrottoConstants.BPS) {
            revert InvalidHookConfiguration();
        }

        crottoDiamond = crottoDiamond_;
        activationToken = activationToken_;
        weth = weth_;
        canonicalTickSpacing = tickSpacing_;
        initialTokenPerWethWad = tokenPerWethWad_;
        maxCombinedHookFeeBps = combinedFeeCeilingBps_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function setHookConfiguration(HookConfiguration calldata configuration) external override onlyDiamond {
        _validateHookConfiguration(configuration);
        _hookConfiguration = configuration;
        emit HookConfigurationSet(configuration);
    }

    function initializeCanonicalPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint256 tokenAmount,
        uint256 wethAmount
    ) external override onlyDiamond nonReentrantHook returns (PoolId poolId, uint128 liquidity) {
        if (_poolInitialized) revert CanonicalPoolAlreadyInitialized();
        if (!IPOLInitialization(crottoDiamond).polInitializationAuthorized()) revert InitializationNotAuthorized();

        PoolKey memory expectedKey = LibCanonicalPool.key(activationToken, weth, address(this), canonicalTickSpacing);
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(expectedKey.toId())) revert InvalidCanonicalPool();
        uint160 expectedPrice = LibCanonicalPool.sqrtPriceX96(activationToken, weth, initialTokenPerWethWad);
        if (sqrtPriceX96 != expectedPrice) revert InvalidCanonicalPrice(expectedPrice, sqrtPriceX96);

        uint256 availableWeth = IERC20(weth).balanceOf(address(this));
        if (availableWeth < wethAmount) revert InsufficientBootstrapWeth(wethAmount, availableWeth);

        uint256 tokenBefore = IERC20(activationToken).balanceOf(address(this));
        IActivationToken(activationToken).mintBootstrapPOL(address(this), tokenAmount);
        uint256 tokenAfter = IERC20(activationToken).balanceOf(address(this));
        uint256 minted = tokenAfter >= tokenBefore ? tokenAfter - tokenBefore : 0;
        if (minted != tokenAmount) revert UnexpectedBootstrapMint(tokenAmount, minted);

        _canonicalPoolKey = expectedKey;
        poolId = expectedKey.toId();
        _canonicalPoolId = poolId;
        _poolInitialized = true;
        _creditPending(expectedKey.currency0, expectedKey.currency0.balanceOfSelf());
        _creditPending(expectedKey.currency1, expectedKey.currency1.balanceOfSelf());

        _initializationActive = true;
        poolManager.initialize(expectedKey, sqrtPriceX96);
        _initializationActive = false;
        (, int24 initializedTick,,) = poolManager.getSlot0(poolId);
        _initializeOracle(initializedTick);
        liquidity = _compoundThroughUnlock();
        if (liquidity == 0) revert EmptyInitialLiquidity();

        _assertPendingSolvency(expectedKey.currency0);
        _assertPendingSolvency(expectedKey.currency1);
        emit CanonicalPoolInitialized(poolId, sqrtPriceX96, tokenAmount, wethAmount, liquidity);
    }

    function donatePOL(uint256 tokenAmount, uint256 wethAmount)
        external
        override
        nonReentrantHook
        returns (uint128 liquidityAdded)
    {
        _enforceInitialized();
        if (tokenAmount == 0 && wethAmount == 0) revert EmptyPOLDonation();

        if (tokenAmount != 0) {
            LibAssetTransfer.pullExact(activationToken, msg.sender, tokenAmount);
            _creditPending(Currency.wrap(activationToken), tokenAmount);
        }
        if (wethAmount != 0) {
            LibAssetTransfer.pullExact(weth, msg.sender, wethAmount);
            _creditPending(Currency.wrap(weth), wethAmount);
        }

        emit POLDonated(msg.sender, tokenAmount, wethAmount);
        liquidityAdded = _compoundThroughUnlock();
    }

    /// @notice Credits finalized round WETH to permanent-liquidity pending without invoking PoolManager.
    function creditPOLWeth(uint256 wethAmount) external override onlyDiamond nonReentrantHook {
        _enforceInitialized();
        if (wethAmount == 0) revert EmptyPOLDonation();
        LibAssetTransfer.pullExact(weth, msg.sender, wethAmount);
        _creditPending(Currency.wrap(weth), wethAmount);
        _assertPendingSolvency(Currency.wrap(weth));
        emit POLDonated(msg.sender, 0, wethAmount);
    }

    function compoundPOL() external override nonReentrantHook returns (uint128 liquidityAdded) {
        _enforceInitialized();
        liquidityAdded = _compoundThroughUnlock();
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller(msg.sender);
        uint8 action = abi.decode(data, (uint8));
        if (action != UNLOCK_COMPOUND) revert InvalidUnlockAction(action);
        return abi.encode(_compoundUnlocked());
    }

    function canonicalPoolKey() external view override returns (PoolKey memory) {
        return _canonicalPoolKey;
    }

    function canonicalPoolId() external view override returns (PoolId) {
        return _canonicalPoolId;
    }

    function hookConfiguration() external view override returns (HookConfiguration memory) {
        return _hookConfiguration;
    }

    function pendingPermanentLiquidity(Currency currency) external view override returns (uint256) {
        return _polPending[currency];
    }

    function totalPendingPermanentLiquidity(Currency currency) external view override returns (uint256) {
        return _totalPending[currency];
    }

    function lockedLiquidity() external view override returns (uint128) {
        return _lockedLiquidity;
    }

    function consult(uint32 secondsAgo)
        external
        view
        override
        returns (int24 arithmeticMeanTick, uint160 sqrtPriceX96)
    {
        if (secondsAgo == 0) revert InvalidOraclePeriod();
        uint32 nowTimestamp = uint32(block.timestamp);
        if (_observationCount == 0 || secondsAgo > nowTimestamp) revert OracleHistoryUnavailable(secondsAgo);
        uint32 target = nowTimestamp - secondsAgo;
        (int256 currentCumulative,) = _currentCumulative(nowTimestamp);

        bool found;
        OracleObservation memory selected;
        for (uint16 offset; offset < _observationCount; ++offset) {
            uint16 index = uint16((uint256(_observationIndex) + ORACLE_CARDINALITY - offset) % ORACLE_CARDINALITY);
            OracleObservation memory candidate = _observations[index];
            if (candidate.timestamp <= target) {
                selected = candidate;
                found = true;
                break;
            }
        }
        if (!found || selected.timestamp == nowTimestamp) revert OracleHistoryUnavailable(secondsAgo);

        uint256 elapsed = uint256(nowTimestamp - selected.timestamp);
        int256 delta = currentCumulative - selected.tickCumulative;
        int256 mean = delta / int256(elapsed);
        if (delta < 0 && delta % int256(elapsed) != 0) --mean;
        if (mean < type(int24).min || mean > type(int24).max) revert OracleHistoryUnavailable(secondsAgo);
        arithmeticMeanTick = int24(mean);
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);
    }

    function oracleState()
        external
        view
        override
        returns (uint16 observationIndex, uint16 observationCount, uint32 lastTimestamp, int24 lastTick)
    {
        return (_observationIndex, _observationCount, _lastOracleTimestamp, _lastOracleTick);
    }

    function poolInitialized() external view override returns (bool) {
        return _poolInitialized;
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        view
        override
        returns (bytes4)
    {
        uint160 expectedPrice = LibCanonicalPool.sqrtPriceX96(activationToken, weth, initialTokenPerWethWad);
        if (
            !_initializationActive || sender != address(this)
                || PoolId.unwrap(key.toId()) != PoolId.unwrap(_canonicalPoolId)
        ) revert UnauthorizedPoolInitialization(sender);
        if (sqrtPriceX96 != expectedPrice) revert InvalidCanonicalPrice(expectedPrice, sqrtPriceX96);
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (
            !_liquidityModificationActive || sender != address(this)
                || PoolId.unwrap(key.toId()) != PoolId.unwrap(_canonicalPoolId) || params.liquidityDelta <= 0
                || params.tickLower != TickMath.minUsableTick(canonicalTickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(canonicalTickSpacing)
                || params.salt != PERMANENT_LIQUIDITY_SALT
        ) revert ExternalLiquidityModification(sender);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert PermanentLiquidityRemovalForbidden();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        uint16 feeBps = exactInput ? _hookConfiguration.inputFeeBps : _hookConfiguration.outputFeeBps;
        uint256 realized = _absolute(params.amountSpecified);
        uint256 charged = Math.mulDiv(realized, feeBps, CrottoConstants.BPS, Math.Rounding.Ceil);
        if (charged == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        Currency specified = params.zeroForOne == exactInput ? key.currency0 : key.currency1;
        _takeExact(specified, charged);
        _allocateAndRoute(specified, charged, exactInput);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(charged.toInt128(), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bool exactInput = params.amountSpecified < 0;
        bool specifiedCurrencyIs0 = exactInput == params.zeroForOne;
        Currency unspecified = specifiedCurrencyIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedDelta = specifiedCurrencyIs0 ? delta.amount1() : delta.amount0();
        uint16 feeBps = exactInput ? _hookConfiguration.outputFeeBps : _hookConfiguration.inputFeeBps;
        uint256 charged =
            Math.mulDiv(_absolute(int256(unspecifiedDelta)), feeBps, CrottoConstants.BPS, Math.Rounding.Ceil);
        if (charged != 0) {
            _takeExact(unspecified, charged);
            _allocateAndRoute(unspecified, charged, !exactInput);
        }

        _compoundUnlocked();
        (, int24 currentTick,,) = poolManager.getSlot0(_canonicalPoolId);
        _recordOracle(currentTick);
        return (IHooks.afterSwap.selector, charged.toInt128());
    }

    function _initializeOracle(int24 tick) private {
        uint32 timestamp = uint32(block.timestamp);
        _lastOracleTimestamp = timestamp;
        _lastOracleTick = tick;
        _observations[0] = OracleObservation({timestamp: timestamp, tickCumulative: 0});
        _observationIndex = 0;
        _observationCount = 1;
        emit OracleObservationRecorded(timestamp, tick, 0);
    }

    function _recordOracle(int24 tick) private {
        uint32 timestamp = uint32(block.timestamp);
        (int256 cumulative, uint32 elapsed) = _currentCumulative(timestamp);
        _tickCumulative = cumulative;
        _lastOracleTimestamp = timestamp;
        _lastOracleTick = tick;
        OracleObservation memory latest = _observations[_observationIndex];
        if (elapsed == 0 || timestamp - latest.timestamp < ORACLE_CHECKPOINT_PERIOD) return;

        _observationIndex = uint16((uint256(_observationIndex) + 1) % ORACLE_CARDINALITY);
        _observations[_observationIndex] = OracleObservation({timestamp: timestamp, tickCumulative: cumulative});
        if (_observationCount < ORACLE_CARDINALITY) ++_observationCount;
        emit OracleObservationRecorded(timestamp, tick, cumulative);
    }

    function _currentCumulative(uint32 timestamp) private view returns (int256 cumulative, uint32 elapsed) {
        elapsed = timestamp - _lastOracleTimestamp;
        cumulative = _tickCumulative + int256(_lastOracleTick) * int256(uint256(elapsed));
    }

    function _allocateAndRoute(Currency currency, uint256 charged, bool inputLeg) private {
        HookConfiguration memory configuration = _hookConfiguration;
        uint256 polAmount = Math.mulDiv(charged, configuration.polShareBps, CrottoConstants.BPS);
        uint256 nftAmount = Math.mulDiv(charged, configuration.nftShareBps, CrottoConstants.BPS);
        uint256 treasuryAmount = charged - polAmount - nftAmount;
        if (ICrottoRewards(crottoDiamond).totalActiveWeight() == 0) {
            polAmount += nftAmount;
            nftAmount = 0;
        }

        _creditPending(currency, polAmount);
        address asset = Currency.unwrap(currency);
        if (treasuryAmount != 0) {
            _transferExact(currency, ICrottoGovernance(crottoDiamond).treasuryReceiver(), treasuryAmount);
        }
        _routeRewardRevenue(currency, asset, nftAmount, treasuryAmount);
        _assertPendingSolvency(currency);
        emit SwapLegFeeAccrued(_canonicalPoolId, currency, inputLeg, charged, polAmount, nftAmount, treasuryAmount);
    }

    function _routeRewardRevenue(Currency currency, address asset, uint256 nftAmount, uint256 treasuryAmount) private {
        if (nftAmount == 0 && treasuryAmount == 0) return;
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = currency.balanceOfSelf();
        if (nftAmount != 0) token.forceApprove(crottoDiamond, nftAmount);
        ICrottoRewards(crottoDiamond).routeHookRevenue(asset, nftAmount, treasuryAmount);
        uint256 afterBalance = currency.balanceOfSelf();
        _enforceExactDebit(currency, beforeBalance, afterBalance, nftAmount);
        uint256 remainingAllowance = token.allowance(address(this), crottoDiamond);
        if (remainingAllowance != 0) revert UnexpectedTokenAllowance(currency, remainingAllowance);
    }

    function _compoundThroughUnlock() private returns (uint128 liquidityAdded) {
        bytes memory result = poolManager.unlock(abi.encode(UNLOCK_COMPOUND));
        liquidityAdded = abi.decode(result, (uint128));
    }

    function _compoundUnlocked() private returns (uint128 liquidityAdded) {
        PoolKey memory key = _canonicalPoolKey;
        if (_lockedLiquidity != 0) _collectPositionFees(key);

        uint256 available0 = _polPending[key.currency0];
        uint256 available1 = _polPending[key.currency1];
        if (available0 == 0 || available1 == 0) return 0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_canonicalPoolId);
        int24 tickLower = TickMath.minUsableTick(canonicalTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(canonicalTickSpacing);
        liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );
        if (liquidityAdded == 0) return 0;

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityAdded)),
            salt: PERMANENT_LIQUIDITY_SALT
        });
        _liquidityModificationActive = true;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        _liquidityModificationActive = false;

        (uint256 amount0, uint256 collected0) = _applyLiquidityDelta(key.currency0, delta.amount0(), available0);
        (uint256 amount1, uint256 collected1) = _applyLiquidityDelta(key.currency1, delta.amount1(), available1);
        _lockedLiquidity += liquidityAdded;

        emit PermanentLiquidityAdded(
            _canonicalPoolId,
            liquidityAdded,
            Currency.unwrap(key.currency0) == activationToken ? amount0 : amount1,
            Currency.unwrap(key.currency0) == weth ? amount0 : amount1
        );
        if (collected0 != 0 || collected1 != 0) {
            emit PermanentLiquidityFeesCollected(
                _canonicalPoolId,
                Currency.unwrap(key.currency0) == activationToken ? collected0 : collected1,
                Currency.unwrap(key.currency0) == weth ? collected0 : collected1
            );
        }
    }

    function _collectPositionFees(PoolKey memory key) private {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(canonicalTickSpacing),
            tickUpper: TickMath.maxUsableTick(canonicalTickSpacing),
            liquidityDelta: 0,
            salt: PERMANENT_LIQUIDITY_SALT
        });
        _liquidityModificationActive = true;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, params, "");
        _liquidityModificationActive = false;

        uint256 available0 = _polPending[key.currency0];
        uint256 available1 = _polPending[key.currency1];
        (, uint256 collected0) = _applyLiquidityDelta(key.currency0, delta.amount0(), available0);
        (, uint256 collected1) = _applyLiquidityDelta(key.currency1, delta.amount1(), available1);
        if (collected0 != 0 || collected1 != 0) {
            emit PermanentLiquidityFeesCollected(
                _canonicalPoolId,
                Currency.unwrap(key.currency0) == activationToken ? collected0 : collected1,
                Currency.unwrap(key.currency0) == weth ? collected0 : collected1
            );
        }
    }

    function _applyLiquidityDelta(Currency currency, int128 delta, uint256 available)
        private
        returns (uint256 amountPaid, uint256 amountCollected)
    {
        if (delta < 0) {
            amountPaid = _absolute(int256(delta));
            if (amountPaid > available) {
                revert PermanentLiquidityExceedsPending(currency, amountPaid, available);
            }
            _polPending[currency] = available - amountPaid;
            _totalPending[currency] -= amountPaid;
            _settle(currency, amountPaid);
        } else if (delta > 0) {
            amountCollected = uint256(uint128(delta));
            _takeExact(currency, amountCollected);
            _creditPending(currency, amountCollected);
        }
        _assertPendingSolvency(currency);
    }

    function _creditPending(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        _polPending[currency] += amount;
        _totalPending[currency] += amount;
    }

    function _takeExact(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        uint256 senderBefore = currency.balanceOf(address(poolManager));
        uint256 receiverBefore = currency.balanceOfSelf();
        poolManager.take(currency, address(this), amount);
        uint256 senderAfter = currency.balanceOf(address(poolManager));
        uint256 receiverAfter = currency.balanceOfSelf();
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _settle(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        poolManager.sync(currency);
        uint256 senderBefore = currency.balanceOfSelf();
        uint256 receiverBefore = currency.balanceOf(address(poolManager));
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        uint256 senderAfter = currency.balanceOfSelf();
        uint256 receiverAfter = currency.balanceOf(address(poolManager));
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
        uint256 settled = poolManager.settle();
        if (settled != amount) revert UnexpectedSettlement(currency, amount, settled);
    }

    function _transferExact(Currency currency, address receiver, uint256 amount) private {
        uint256 senderBefore = currency.balanceOfSelf();
        uint256 receiverBefore = currency.balanceOf(receiver);
        IERC20(Currency.unwrap(currency)).safeTransfer(receiver, amount);
        uint256 senderAfter = currency.balanceOfSelf();
        uint256 receiverAfter = currency.balanceOf(receiver);
        _enforceExactDebit(currency, senderBefore, senderAfter, amount);
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (received != amount) revert IncompatiblePoolCurrency(currency, amount, received);
    }

    function _assertPendingSolvency(Currency currency) private view {
        uint256 required = _totalPending[currency];
        uint256 available = currency.balanceOfSelf();
        if (available < required) revert PendingLiquidityInsolvent(currency, required, available);
    }

    function _enforceExactDebit(Currency currency, uint256 beforeBalance, uint256 afterBalance, uint256 expected)
        private
        pure
    {
        uint256 actual = beforeBalance >= afterBalance ? beforeBalance - afterBalance : 0;
        if (actual != expected) revert UnexpectedTokenDebit(currency, expected, actual);
    }

    function _validateHookConfiguration(HookConfiguration memory configuration) private view {
        uint256 combinedFee = uint256(configuration.inputFeeBps) + configuration.outputFeeBps;
        uint256 allocation =
            uint256(configuration.polShareBps) + configuration.nftShareBps + configuration.treasuryShareBps;
        if (combinedFee > maxCombinedHookFeeBps || allocation != CrottoConstants.BPS) {
            revert InvalidHookConfiguration();
        }
    }

    function _enforceInitialized() private view {
        if (!_poolInitialized) revert CanonicalPoolNotInitialized();
    }

    function _absolute(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
    }
}
