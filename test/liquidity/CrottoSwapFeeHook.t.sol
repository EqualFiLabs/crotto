// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {ICrottoSwapFeeHook} from "../../src/interfaces/ICrottoSwapFeeHook.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {CrottoSwapFeeHook} from "../../src/liquidity/CrottoSwapFeeHook.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {HookConfiguration} from "../../src/types/CrottoTypes.sol";

contract CrottoHookController {
    address public hook;
    address public immutable weth;
    bool private initializationAuthorized;

    constructor(address weth_) {
        weth = weth_;
    }

    function setHook(address hook_) external {
        require(hook == address(0));
        hook = hook_;
    }

    function polInitializationAuthorized() external view returns (bool) {
        return initializationAuthorized;
    }

    function setHookConfiguration(HookConfiguration calldata configuration) external {
        ICrottoSwapFeeHook(hook).setHookConfiguration(configuration);
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96, uint256 tokenAmount, uint256 wethAmount)
        external
        returns (PoolId poolId, uint128 liquidity)
    {
        initializationAuthorized = true;
        IERC20(weth).transfer(hook, wethAmount);
        (poolId, liquidity) =
            ICrottoSwapFeeHook(hook).initializeCanonicalPool(key, sqrtPriceX96, tokenAmount, wethAmount);
        initializationAuthorized = false;
    }
}

interface IV4TestDeployment {
    function manager() external view returns (IPoolManager);

    function donateRouter() external view returns (address);

    function modifyLiquidityRouter() external view returns (address);

    function swapRouter() external view returns (address);
}

interface IPoolSwapRouter {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory settings, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta);
}

interface IPoolDonateRouter {
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta);
}

interface IPoolModifyLiquidityRouter {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (BalanceDelta delta);
}

contract CrottoSwapFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 private constant REQUIRED_WETH = 30 ether;
    uint256 private constant TOKEN_PER_WETH_WAD = 10_000 ether;
    int24 private constant TICK_SPACING = 60;

    WETH9 private wethToken;
    ActivationToken private token;
    CrottoHookController private controller;
    CrottoSwapFeeHook private hook;
    PoolKey private canonicalKey;
    PoolId private canonicalId;
    IPoolManager private manager;
    IPoolDonateRouter private donateRouter;
    IPoolModifyLiquidityRouter private modifyLiquidityRouter;
    IPoolSwapRouter private swapRouter;

    function setUp() public {
        IV4TestDeployment v4 = IV4TestDeployment(_deployArtifact("out/V4TestDeployment.sol/V4TestDeployment.json"));
        manager = v4.manager();
        donateRouter = IPoolDonateRouter(v4.donateRouter());
        modifyLiquidityRouter = IPoolModifyLiquidityRouter(v4.modifyLiquidityRouter());
        swapRouter = IPoolSwapRouter(v4.swapRouter());
        wethToken = new WETH9();
        controller = new CrottoHookController(address(wethToken));

        address expectedToken = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory constructorArgs = abi.encode(
            manager,
            address(controller),
            expectedToken,
            address(wethToken),
            TICK_SPACING,
            TOKEN_PER_WETH_WAD,
            uint16(100)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(CrottoSwapFeeHook).creationCode, constructorArgs);

        token = new ActivationToken(address(this), address(controller), expectedHook);
        assertEq(address(token), expectedToken);
        hook = new CrottoSwapFeeHook{salt: salt}(
            manager, address(controller), address(token), address(wethToken), TICK_SPACING, TOKEN_PER_WETH_WAD, 100
        );
        assertEq(address(hook), expectedHook);
        controller.setHook(address(hook));
        controller.setHookConfiguration(_configuration());

        canonicalKey = LibCanonicalPool.key(address(token), address(wethToken), address(hook), TICK_SPACING);
        canonicalId = canonicalKey.toId();

        token.approve(address(hook), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        wethToken.approve(address(hook), type(uint256).max);
        wethToken.approve(address(donateRouter), type(uint256).max);
        wethToken.approve(address(swapRouter), type(uint256).max);
    }

    function test_MinedAddressAndImmutableBindingsMatchCanonicalPermissions() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.afterInitialize);
        assertTrue(permissions.beforeAddLiquidity);
        assertTrue(permissions.beforeRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.afterSwapReturnDelta);
        assertEq(hook.crottoDiamond(), address(controller));
        assertEq(hook.activationToken(), address(token));
        assertEq(hook.weth(), address(wethToken));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.canonicalTickSpacing(), TICK_SPACING);
        assertEq(hook.initialTokenPerWethWad(), TOKEN_PER_WETH_WAD);
        assertEq(hook.maxCombinedHookFeeBps(), 100);
    }

    function test_DiamondInitializesOneZeroFeeCanonicalPoolWithPermanentLiquidity() public {
        _initialize(REQUIRED_WETH + 7 ether);

        assertTrue(hook.poolInitialized());
        assertTrue(token.bootstrapMintExecuted());
        assertEq(PoolId.unwrap(hook.canonicalPoolId()), PoolId.unwrap(canonicalId));
        assertEq(hook.canonicalPoolKey().fee, 0);
        assertEq(hook.canonicalPoolKey().tickSpacing, TICK_SPACING);
        assertGt(hook.lockedLiquidity(), 0);
        (uint160 actualPrice,,,) = manager.getSlot0(canonicalId);
        assertEq(actualPrice, LibCanonicalPool.sqrtPriceX96(address(token), address(wethToken), TOKEN_PER_WETH_WAD));
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));

        vm.expectRevert(CrottoSwapFeeHook.CanonicalPoolAlreadyInitialized.selector);
        controller.initialize(canonicalKey, actualPrice, REQUIRED_WETH * 10_000, 0);
    }

    function test_ExternalInitializationCannotSquatCanonicalKeyOrPrice() public {
        uint160 price = LibCanonicalPool.sqrtPriceX96(address(token), address(wethToken), TOKEN_PER_WETH_WAD);
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(CrottoSwapFeeHook.UnauthorizedPoolInitialization.selector, address(this))
            )
        );
        manager.initialize(canonicalKey, price + 1);
        (uint160 actualPrice,,,) = manager.getSlot0(canonicalId);
        assertEq(actualPrice, 0);

        _initialize(REQUIRED_WETH);
        assertEq(hook.canonicalPoolKey().fee, 0);
        assertNotEq(Currency.unwrap(hook.canonicalPoolKey().currency0), address(0));
    }

    function test_ExternalLiquidityAdditionsAndRemovalsAlwaysRevert() public {
        _initialize(REQUIRED_WETH);
        ModifyLiquidityParams memory add = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: 1,
            salt: bytes32(uint256(123))
        });
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(
                    CrottoSwapFeeHook.ExternalLiquidityModification.selector, address(modifyLiquidityRouter)
                )
            )
        );
        modifyLiquidityRouter.modifyLiquidity(canonicalKey, add, "");

        add.liquidityDelta = -1;
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(CrottoSwapFeeHook.PermanentLiquidityRemovalForbidden.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(canonicalKey, add, "");
    }

    function test_PermissionlessOneAndTwoAssetDonationsCreateNoWithdrawablePosition() public {
        _initialize(REQUIRED_WETH);
        uint128 initialLiquidity = hook.lockedLiquidity();

        hook.donatePOL(1_000 ether, 0);
        assertGt(hook.pendingPermanentLiquidity(Currency.wrap(address(token))), 0);
        _assertPendingSolvent(Currency.wrap(address(token)));

        _mintWeth(1 ether);
        hook.donatePOL(0, 1 ether);
        assertGt(hook.lockedLiquidity(), initialLiquidity);
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));

        vm.expectRevert(CrottoSwapFeeHook.EmptyPOLDonation.selector);
        hook.donatePOL(0, 0);
    }

    function test_BackupCompoundingCollectsDonatedPositionFeesIntoPermanentLiquidity() public {
        _initialize(REQUIRED_WETH);
        uint128 liquidityBefore = hook.lockedLiquidity();
        _mintWeth(2 ether);

        bool tokenIsCurrency0 = Currency.unwrap(canonicalKey.currency0) == address(token);
        donateRouter.donate(
            canonicalKey, tokenIsCurrency0 ? 1_000 ether : 1 ether, tokenIsCurrency0 ? 1 ether : 1_000 ether, ""
        );
        uint128 liquidityAdded = hook.compoundPOL();

        assertGt(liquidityAdded, 0);
        assertGt(hook.lockedLiquidity(), liquidityBefore);
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));
    }

    function _wrappedHookRevert(bytes4 selector, bytes memory reason) private view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_HookConfigurationIsDiamondOnlyConservedAndCapped() public {
        HookConfiguration memory configuration = _configuration();
        vm.expectRevert(abi.encodeWithSelector(CrottoSwapFeeHook.OnlyCrottoDiamond.selector, address(this)));
        hook.setHookConfiguration(configuration);

        configuration.outputFeeBps = 51;
        vm.expectRevert(CrottoSwapFeeHook.InvalidHookConfiguration.selector);
        controller.setHookConfiguration(configuration);

        configuration = _configuration();
        configuration.treasuryShareBps = 999;
        vm.expectRevert(CrottoSwapFeeHook.InvalidHookConfiguration.selector);
        controller.setHookConfiguration(configuration);
    }

    function test_CanonicalPoolSwapsRemainLiveBeforeBilateralFeesAreEnabled() public {
        _initialize(REQUIRED_WETH);
        _mintWeth(1 ether);
        bool wethIsCurrency0 = Currency.unwrap(canonicalKey.currency0) == address(wethToken);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 wethBefore = wethToken.balanceOf(address(this));

        swapRouter.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: wethIsCurrency0,
                amountSpecified: -int256(0.1 ether),
                sqrtPriceLimitX96: wethIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            IPoolSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertLt(wethToken.balanceOf(address(this)), wethBefore);
        assertGt(token.balanceOf(address(this)), tokenBefore);
    }

    function test_DonationAndCompoundingRequireInitializedPool() public {
        vm.expectRevert(CrottoSwapFeeHook.CanonicalPoolNotInitialized.selector);
        hook.donatePOL(1, 0);
        vm.expectRevert(CrottoSwapFeeHook.CanonicalPoolNotInitialized.selector);
        hook.compoundPOL();
    }

    function _initialize(uint256 wethAmount) private {
        _mintWeth(wethAmount);
        wethToken.transfer(address(controller), wethAmount);
        uint160 price = LibCanonicalPool.sqrtPriceX96(address(token), address(wethToken), TOKEN_PER_WETH_WAD);
        controller.initialize(canonicalKey, price, REQUIRED_WETH * 10_000, wethAmount);
    }

    function _mintWeth(uint256 amount) private {
        vm.deal(address(this), address(this).balance + amount);
        wethToken.deposit{value: amount}();
    }

    function _assertPendingSolvent(Currency currency) private view {
        uint256 pending = hook.pendingPermanentLiquidity(currency);
        assertEq(hook.totalPendingPermanentLiquidity(currency), pending);
        assertGe(currency.balanceOf(address(hook)), pending);
    }

    function _configuration() private pure returns (HookConfiguration memory configuration) {
        configuration = HookConfiguration({
            inputFeeBps: CrottoConstants.INITIAL_HOOK_INPUT_FEE_BPS,
            outputFeeBps: CrottoConstants.INITIAL_HOOK_OUTPUT_FEE_BPS,
            polShareBps: CrottoConstants.INITIAL_HOOK_POL_SHARE_BPS,
            nftShareBps: CrottoConstants.INITIAL_HOOK_NFT_SHARE_BPS,
            treasuryShareBps: CrottoConstants.INITIAL_HOOK_TREASURY_SHARE_BPS
        });
    }

    function _deployArtifact(string memory artifact) private returns (address deployed) {
        bytes memory creationCode = vm.getCode(artifact);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "artifact deployment failed");
    }
}
