// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
import {RewardAccountingFacet} from "../../src/diamond/facets/RewardAccountingFacet.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {LibRewardAccounting} from "../../src/libraries/LibRewardAccounting.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../src/libraries/storage/LibLotteryStorage.sol";
import {LibRewardsStorage} from "../../src/libraries/storage/LibRewardsStorage.sol";
import {LibTreasuryStorage} from "../../src/libraries/storage/LibTreasuryStorage.sol";
import {LibVaultStorage} from "../../src/libraries/storage/LibVaultStorage.sol";
import {CrottoSwapFeeHook} from "../../src/liquidity/CrottoSwapFeeHook.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {HookConfiguration} from "../../src/types/CrottoTypes.sol";

contract CrottoHookController is RewardAccountingFacet {
    address public hook;
    address public immutable weth;
    bool private initializationAuthorized;

    constructor(address weth_) {
        weth = weth_;
        LibGovernanceStorage.layout().immutableConfiguration.weth = weth_;
        LibGovernanceStorage.layout().treasuryReceiver = address(0xBEEF);
    }

    function setHook(address hook_, address token_) external {
        require(hook == address(0));
        hook = hook_;
        LibGovernanceStorage.layout().immutableConfiguration.canonicalHook = hook_;
        LibGovernanceStorage.layout().immutableConfiguration.activationToken = token_;
    }

    function polInitializationAuthorized() external view returns (bool) {
        return initializationAuthorized;
    }

    function setHookConfiguration(HookConfiguration calldata configuration) external {
        ICrottoSwapFeeHook(hook).setHookConfiguration(configuration);
    }

    function setTotalActiveWeight(uint256 weight) external {
        LibRewardAccounting.setPositionWeight(1, weight == 0 ? 0 : 1, weight);
    }

    function treasuryReceiver() external view returns (address) {
        return LibGovernanceStorage.layout().treasuryReceiver;
    }

    function routedRewards(address asset) external view returns (uint256) {
        LibRewardsStorage.Layout storage state = LibRewardsStorage.layout();
        return asset == weth ? state.wethBook.indexedAmount : state.tokenBook.indexedAmount;
    }

    function seedIsolatedAccounting(address caller) external {
        // Direct sentinel writes keep this storage-isolation check narrow; the fee path itself still uses the real hook,
        // PoolManager, currencies, and permanent position.
        LibRewardsStorage.Layout storage rewards = LibRewardsStorage.layout();
        rewards.wethBook.indexRay = 9;
        rewards.wethBook.indexRemainder = 10;
        rewards.wethBook.indexedAmount = 11;
        rewards.wethBook.crystallizedAmount = 12;
        rewards.wethBook.totalClaimable = 13;
        rewards.tokenBook.indexRay = 19;
        rewards.tokenBook.indexRemainder = 20;
        rewards.tokenBook.indexedAmount = 21;
        rewards.tokenBook.crystallizedAmount = 22;
        rewards.tokenBook.totalClaimable = 23;
        rewards.totalActiveWeight = 24;

        LibVaultStorage.layout().tokenBacking = 31;
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        lottery.currentRoundId = 41;
        lottery.totalWinnerPoolWethLiability = 42;
        lottery.totalPlayerTokenLiability = 43;
        lottery.rounds[41].ticketCount = 44;
        lottery.rounds[41].winnerPoolWeth = 45;
        lottery.rounds[41].totalPlayerRewardLiability = 46;
        lottery.rounds[41].unclaimedPlayerRewardLiability = 47;
        lottery.playerTicketCounts[41][caller] = 48;
        lottery.playerRewardClaimed[41][caller] = true;

        LibTreasuryStorage.Layout storage treasury = LibTreasuryStorage.layout();
        treasury.__reservedLegacyTreasuryWeth = 49;
        treasury.__reservedLegacyTreasuryToken = 50;
        treasury.operationsReserveEth = 51;
        treasury.totalCallerCreditsEth = 52;
        treasury.callerCreditsEth[caller] = 53;
        treasury.callerRewardCredited[keccak256("isolated-accounting")] = true;
    }

    function isolatedAccountingDigest(address caller) external view returns (bytes32) {
        LibRewardsStorage.Layout storage rewards = LibRewardsStorage.layout();
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        LibTreasuryStorage.Layout storage treasury = LibTreasuryStorage.layout();
        bytes32 rewardDigest = keccak256(
            abi.encode(
                rewards.wethBook.indexRay,
                rewards.wethBook.indexRemainder,
                rewards.wethBook.indexedAmount,
                rewards.wethBook.crystallizedAmount,
                rewards.wethBook.totalClaimable,
                rewards.tokenBook.indexRay,
                rewards.tokenBook.indexRemainder,
                rewards.tokenBook.indexedAmount,
                rewards.tokenBook.crystallizedAmount,
                rewards.tokenBook.totalClaimable,
                rewards.totalActiveWeight
            )
        );
        bytes32 lotteryDigest = keccak256(
            abi.encode(
                lottery.currentRoundId,
                lottery.totalWinnerPoolWethLiability,
                lottery.totalPlayerTokenLiability,
                lottery.rounds[41].ticketCount,
                lottery.rounds[41].winnerPoolWeth,
                lottery.rounds[41].totalPlayerRewardLiability,
                lottery.rounds[41].unclaimedPlayerRewardLiability,
                lottery.playerTicketCounts[41][caller],
                lottery.playerRewardClaimed[41][caller]
            )
        );
        bytes32 treasuryDigest = keccak256(
            abi.encode(
                treasury.__reservedLegacyTreasuryWeth,
                treasury.__reservedLegacyTreasuryToken,
                treasury.operationsReserveEth,
                treasury.totalCallerCreditsEth,
                treasury.callerCreditsEth[caller],
                treasury.callerRewardCredited[keccak256("isolated-accounting")]
            )
        );
        return keccak256(abi.encode(rewardDigest, LibVaultStorage.layout().tokenBacking, lotteryDigest, treasuryDigest));
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

contract HookAdversarialToken is ERC20 {
    address public canonicalHook;
    address public taxedSender;
    address public shortReceiver;
    bool public bootstrapMintExecuted;
    bool public preserveAllowance;

    constructor() ERC20("Adversarial Crotto", "aCROTTO") {}

    function setCanonicalHook(address hook_) external {
        require(canonicalHook == address(0), "hook already set");
        canonicalHook = hook_;
    }

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function setShortReceiver(address receiver) external {
        shortReceiver = receiver;
    }

    function setPreserveAllowance(bool preserve) external {
        preserveAllowance = preserve;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function mintBootstrapPOL(address receiver, uint256 amount) external {
        require(msg.sender == canonicalHook, "not hook");
        require(!bootstrapMintExecuted, "bootstrap minted");
        bootstrapMintExecuted = true;
        _mint(receiver, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from == taxedSender && value != 0) {
            super._update(from, address(0), 1);
        }
        if (to != address(0) && to == shortReceiver && value != 0) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
            return;
        }
        super._update(from, to, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal override {
        if (!preserveAllowance) super._spendAllowance(owner, spender, value);
    }
}

contract AdversarialHookController {
    using SafeERC20 for IERC20;

    address public hook;
    address public immutable weth;
    bool public initializationAuthorized;
    bool public activeRewards;
    bool public leaveRewardAllowance;
    address public treasury = address(0xBEEF);

    constructor(address weth_) {
        weth = weth_;
    }

    function setHook(address hook_) external {
        require(hook == address(0), "hook already set");
        hook = hook_;
    }

    function setHookConfiguration(HookConfiguration calldata configuration) external {
        ICrottoSwapFeeHook(hook).setHookConfiguration(configuration);
    }

    function setRewardMode(bool active, bool leaveAllowance) external {
        activeRewards = active;
        leaveRewardAllowance = leaveAllowance;
    }

    function totalActiveWeight() external view returns (uint256) {
        return activeRewards ? 1 : 0;
    }

    function polInitializationAuthorized() external view returns (bool) {
        return initializationAuthorized;
    }

    function treasuryReceiver() external view returns (address) {
        return treasury;
    }

    function routeHookRevenue(address asset, uint256 rewardAmount, uint256) external {
        require(msg.sender == hook, "not hook");
        if (rewardAmount != 0 && !leaveRewardAllowance) {
            IERC20(asset).safeTransferFrom(msg.sender, address(this), rewardAmount);
        }
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96, uint256 tokenAmount, uint256 wethAmount) external {
        initializationAuthorized = true;
        IERC20(weth).safeTransfer(hook, wethAmount);
        ICrottoSwapFeeHook(hook).initializeCanonicalPool(key, sqrtPriceX96, tokenAmount, wethAmount);
        initializationAuthorized = false;
    }
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
        controller.setHook(address(hook), address(token));
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
        uint128 lockedBefore = hook.lockedLiquidity();
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
        assertEq(hook.lockedLiquidity(), lockedBefore);

        add.liquidityDelta = -1;
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(CrottoSwapFeeHook.PermanentLiquidityRemovalForbidden.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(canonicalKey, add, "");
        assertEq(hook.lockedLiquidity(), lockedBefore);
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

    function test_DonationsPullExactAssetsWithoutCreatingAllowanceOrClaims() public {
        _initialize(REQUIRED_WETH);
        _mintWeth(2 ether);
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 wethBefore = wethToken.balanceOf(address(this));
        uint256 controllerTokenBefore = token.balanceOf(address(controller));
        uint256 controllerWethBefore = wethToken.balanceOf(address(controller));

        hook.donatePOL(2_000 ether, 2 ether);

        assertEq(tokenBefore - token.balanceOf(address(this)), 2_000 ether);
        assertEq(wethBefore - wethToken.balanceOf(address(this)), 2 ether);
        assertEq(token.balanceOf(address(controller)), controllerTokenBefore);
        assertEq(wethToken.balanceOf(address(controller)), controllerWethBefore);
        assertEq(token.allowance(address(hook), address(controller)), 0);
        assertEq(wethToken.allowance(address(hook), address(controller)), 0);
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));
    }

    function test_TokenHeavyDonationKeepsUnmatchedValueForLaterCompounding() public {
        _initialize(REQUIRED_WETH);
        uint128 liquidityBefore = hook.lockedLiquidity();

        hook.donatePOL(500_000 ether, 0);
        uint256 unmatchedToken = hook.pendingPermanentLiquidity(Currency.wrap(address(token)));
        assertGt(unmatchedToken, 400_000 ether);

        _mintWeth(1 ether);
        hook.donatePOL(0, 1 ether);
        assertGt(hook.lockedLiquidity(), liquidityBefore);
        assertLt(hook.pendingPermanentLiquidity(Currency.wrap(address(token))), unmatchedToken);
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));
    }

    function test_WethHeavyDonationKeepsUnmatchedValueForLaterCompounding() public {
        _initialize(REQUIRED_WETH);
        uint128 liquidityBefore = hook.lockedLiquidity();
        _mintWeth(50 ether);

        hook.donatePOL(0, 50 ether);
        uint256 unmatchedWeth = hook.pendingPermanentLiquidity(Currency.wrap(address(wethToken)));
        assertGt(unmatchedWeth, 49 ether);

        hook.donatePOL(1_000 ether, 0);
        assertGt(hook.lockedLiquidity(), liquidityBefore);
        assertLt(hook.pendingPermanentLiquidity(Currency.wrap(address(wethToken))), unmatchedWeth);
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));
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

    function test_PermanentPositionFeesRemainPOLAndLeaveOtherBooksUntouched() public {
        _initialize(REQUIRED_WETH);
        controller.seedIsolatedAccounting(address(this));
        bytes32 accountingBefore = controller.isolatedAccountingDigest(address(this));
        address treasury = controller.treasuryReceiver();
        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        uint256 treasuryWethBefore = wethToken.balanceOf(treasury);
        uint256 pendingTokenBefore = hook.pendingPermanentLiquidity(Currency.wrap(address(token)));

        uint256 positionFee = 100_000 ether;
        bool tokenIsCurrency0 = Currency.unwrap(canonicalKey.currency0) == address(token);
        donateRouter.donate(canonicalKey, tokenIsCurrency0 ? positionFee : 0, tokenIsCurrency0 ? 0 : positionFee, "");
        hook.compoundPOL();

        assertGt(hook.pendingPermanentLiquidity(Currency.wrap(address(token))), pendingTokenBefore);
        assertEq(controller.isolatedAccountingDigest(address(this)), accountingBefore);
        assertEq(token.balanceOf(treasury), treasuryTokenBefore);
        assertEq(wethToken.balanceOf(treasury), treasuryWethBefore);
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

    function test_LiveAsymmetricRatesConserveBothFeeLegsAtTheCeiling() public {
        HookConfiguration memory configuration = HookConfiguration({
            inputFeeBps: 37, outputFeeBps: 63, polShareBps: 3_333, nftShareBps: 1, treasuryShareBps: 6_666
        });
        controller.setHookConfiguration(configuration);
        _assertBilateralSwap(true, true, true);
    }

    function test_ExactInputTokenToWethChargesBothLegsAndRedirectsInactiveNftShare() public {
        _assertBilateralSwap(true, true, false);
    }

    function test_ExactInputWethToTokenChargesBothLegsAndRoutesActiveNftRewards() public {
        _assertBilateralSwap(false, true, true);
    }

    function test_ExactOutputTokenToWethChargesBothLegsAndRoutesActiveNftRewards() public {
        _assertBilateralSwap(true, false, true);
    }

    function test_ExactOutputWethToTokenChargesBothLegsAndRedirectsInactiveNftShare() public {
        _assertBilateralSwap(false, false, false);
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

    function _assertBilateralSwap(bool tokenToWeth, bool exactInput, bool activeRewards) private {
        _initialize(REQUIRED_WETH);
        _mintWeth(2 ether);
        controller.setTotalActiveWeight(activeRewards ? 1 : 0);

        bool tokenIsCurrency0 = Currency.unwrap(canonicalKey.currency0) == address(token);
        bool zeroForOne = tokenToWeth == tokenIsCurrency0;
        uint256 amount = tokenToWeth ? (exactInput ? 1_000 ether : 0.05 ether) : (exactInput ? 0.1 ether : 500 ether);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: exactInput ? -int256(amount) : int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        uint128 liquidityBefore = hook.lockedLiquidity();
        vm.recordLogs();
        swapRouter.swap(
            canonicalKey, params, IPoolSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertFeeEvents(logs, activeRewards, exactInput, amount);

        assertGt(hook.lockedLiquidity(), liquidityBefore);
        _assertPendingSolvent(Currency.wrap(address(token)));
        _assertPendingSolvent(Currency.wrap(address(wethToken)));
    }

    function _assertFeeEvents(Vm.Log[] memory logs, bool activeRewards, bool exactInput, uint256 specifiedAmount)
        private
        view
    {
        HookConfiguration memory configuration = hook.hookConfiguration();
        bytes32 feeEvent = keccak256("SwapLegFeeAccrued(bytes32,address,bool,uint256,uint256,uint256,uint256)");
        uint256 found;
        bool sawToken;
        bool sawWeth;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != feeEvent) continue;
            address asset = address(uint160(uint256(logs[i].topics[2])));
            if (asset == address(token)) sawToken = true;
            if (asset == address(wethToken)) sawWeth = true;
            (uint256 feeAmount, uint256 polAmount, uint256 nftAmount, uint256 treasuryAmount) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            bool inputLeg = uint256(logs[i].topics[3]) != 0;
            if (inputLeg == exactInput) {
                uint256 specifiedFeeBps = exactInput ? configuration.inputFeeBps : configuration.outputFeeBps;
                assertEq(
                    feeAmount,
                    (specifiedAmount * specifiedFeeBps + CrottoConstants.BPS - 1) / CrottoConstants.BPS,
                    "specified-leg ceil fee"
                );
            }
            uint256 expectedPol = feeAmount * configuration.polShareBps / CrottoConstants.BPS;
            uint256 expectedNft = feeAmount * configuration.nftShareBps / CrottoConstants.BPS;
            uint256 expectedTreasury = feeAmount - expectedPol - expectedNft;
            assertEq(polAmount + nftAmount + treasuryAmount, feeAmount);
            assertEq(treasuryAmount, expectedTreasury);
            if (activeRewards) {
                assertEq(polAmount, expectedPol);
                assertEq(nftAmount, expectedNft);
            } else {
                assertEq(nftAmount, 0);
                assertEq(polAmount, expectedPol + expectedNft);
            }
            ++found;
        }
        assertEq(found, 2, "input and output fee events");
        assertTrue(sawToken && sawWeth, "bilateral assets");

        uint256 routed = controller.routedRewards(address(token)) + controller.routedRewards(address(wethToken));
        if (activeRewards) assertGt(routed, 0);
        else assertEq(routed, 0);
        assertGt(token.balanceOf(controller.treasuryReceiver()) + wethToken.balanceOf(controller.treasuryReceiver()), 0);
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

contract CrottoSwapFeeHookAdversarialTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 private constant REQUIRED_WETH = 30 ether;
    uint256 private constant TOKEN_PER_WETH_WAD = 10_000 ether;
    int24 private constant TICK_SPACING = 60;

    HookAdversarialToken private token;
    WETH9 private weth;
    AdversarialHookController private controller;
    CrottoSwapFeeHook private hook;
    IPoolManager private manager;
    IPoolSwapRouter private swapRouter;
    PoolKey private canonicalKey;

    function setUp() public {
        IV4TestDeployment v4 = IV4TestDeployment(_deployArtifact("out/V4TestDeployment.sol/V4TestDeployment.json"));
        manager = v4.manager();
        swapRouter = IPoolSwapRouter(v4.swapRouter());
        weth = new WETH9();
        token = new HookAdversarialToken();
        controller = new AdversarialHookController(address(weth));

        bytes memory constructorArgs = abi.encode(
            manager, address(controller), address(token), address(weth), TICK_SPACING, TOKEN_PER_WETH_WAD, uint16(100)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(CrottoSwapFeeHook).creationCode, constructorArgs);
        hook = new CrottoSwapFeeHook{salt: salt}(
            manager, address(controller), address(token), address(weth), TICK_SPACING, TOKEN_PER_WETH_WAD, 100
        );
        assertEq(address(hook), expectedHook);
        token.setCanonicalHook(address(hook));
        controller.setHook(address(hook));
        controller.setHookConfiguration(_configuration());

        canonicalKey = LibCanonicalPool.key(address(token), address(weth), address(hook), TICK_SPACING);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(hook), type(uint256).max);
        _mintWeth(REQUIRED_WETH + 10 ether);
        assertTrue(weth.transfer(address(controller), REQUIRED_WETH));
        controller.initialize(
            canonicalKey,
            LibCanonicalPool.sqrtPriceX96(address(token), address(weth), TOKEN_PER_WETH_WAD),
            REQUIRED_WETH * 10_000,
            REQUIRED_WETH
        );
    }

    function test_IncompatibleReceiverCreditRevertsTheSwap() public {
        token.setShortReceiver(address(hook));
        _assertSwapRevertsWith(CrottoSwapFeeHook.IncompatiblePoolCurrency.selector);
    }

    function test_SenderExtraPoolManagerDebitRevertsTheSwap() public {
        token.setTaxedSender(address(manager));
        _assertSwapRevertsWith(CrottoSwapFeeHook.UnexpectedTokenDebit.selector);
    }

    function test_SenderExtraHookDebitRevertsTheSwap() public {
        token.setTaxedSender(address(hook));
        _assertSwapRevertsWith(CrottoSwapFeeHook.UnexpectedTokenDebit.selector);
    }

    function test_ResidualRewardAllowanceRevertsTheSwap() public {
        controller.setRewardMode(true, false);
        token.setPreserveAllowance(true);
        _assertSwapRevertsWith(CrottoSwapFeeHook.UnexpectedTokenAllowance.selector);
        assertEq(token.allowance(address(hook), address(controller)), 0, "rollback clears approval");
    }

    function test_UnexpectedSettlementRevertsDonationCompounding() public {
        _mintWeth(1 ether);
        vm.mockCall(address(manager), abi.encodeWithSelector(IPoolManager.settle.selector), abi.encode(uint256(0)));
        vm.expectPartialRevert(CrottoSwapFeeHook.UnexpectedSettlement.selector);
        hook.donatePOL(1_000 ether, 1 ether);
        vm.clearMockedCalls();
    }

    function executeTokenToWeth() external {
        require(msg.sender == address(this), "self only");
        bool tokenIsCurrency0 = Currency.unwrap(canonicalKey.currency0) == address(token);
        swapRouter.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: -int256(1_000 ether),
                sqrtPriceLimitX96: tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            IPoolSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _assertSwapRevertsWith(bytes4 expectedInnerSelector) private {
        (bool success, bytes memory revertData) = address(this).call(abi.encodeCall(this.executeTokenToWeth, ()));
        assertFalse(success, "swap must revert");
        assertEq(bytes4(revertData), CustomRevert.WrappedError.selector, "PoolManager wrapper");

        bytes memory encodedArguments = new bytes(revertData.length - 4);
        for (uint256 i; i < encodedArguments.length; ++i) {
            encodedArguments[i] = revertData[i + 4];
        }
        (address target, bytes4 callbackSelector, bytes memory innerReason,) =
            abi.decode(encodedArguments, (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertTrue(
            callbackSelector == IHooks.beforeSwap.selector || callbackSelector == IHooks.afterSwap.selector,
            "swap callback"
        );
        assertEq(bytes4(innerReason), expectedInnerSelector, "inner hook error");
    }

    function _mintWeth(uint256 amount) private {
        vm.deal(address(this), address(this).balance + amount);
        weth.deposit{value: amount}();
    }

    function _configuration() private pure returns (HookConfiguration memory configuration) {
        configuration = HookConfiguration({
            inputFeeBps: 50, outputFeeBps: 50, polShareBps: 5_000, nftShareBps: 4_000, treasuryShareBps: 1_000
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
