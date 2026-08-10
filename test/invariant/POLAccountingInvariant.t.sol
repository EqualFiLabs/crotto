// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CrottoConstants} from "../../src/libraries/CrottoConstants.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {CrottoSwapFeeHook} from "../../src/liquidity/CrottoSwapFeeHook.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";
import {HookConfiguration} from "../../src/types/CrottoTypes.sol";
import {
    CrottoHookController,
    IPoolDonateRouter,
    IPoolSwapRouter,
    IV4TestDeployment
} from "../liquidity/CrottoSwapFeeHook.t.sol";

contract POLAccountingHandler is Test {
    uint256 private constant MAX_TOKEN_ACTION = 10_000 ether;
    uint256 private constant MAX_WETH_ACTION = 1 ether;

    CrottoSwapFeeHook public immutable HOOK;
    ActivationToken public immutable TOKEN;
    WETH9 public immutable WETH;
    IPoolDonateRouter public immutable DONATE_ROUTER;
    IPoolSwapRouter public immutable SWAP_ROUTER;
    PoolKey private canonicalKey;
    bool private tokenIsCurrency0;

    uint128 public immutable INITIAL_LOCKED_LIQUIDITY;
    uint128 public lastLockedLiquidity;
    bool public liquidityDecreased;
    uint256 public successfulActions;

    constructor(
        CrottoSwapFeeHook hook_,
        ActivationToken token_,
        WETH9 weth_,
        IPoolDonateRouter donateRouter_,
        IPoolSwapRouter swapRouter_,
        PoolKey memory canonicalKey_
    ) {
        HOOK = hook_;
        TOKEN = token_;
        WETH = weth_;
        DONATE_ROUTER = donateRouter_;
        SWAP_ROUTER = swapRouter_;
        canonicalKey = canonicalKey_;
        tokenIsCurrency0 = Currency.unwrap(canonicalKey_.currency0) == address(token_);
        INITIAL_LOCKED_LIQUIDITY = hook_.lockedLiquidity();
        lastLockedLiquidity = INITIAL_LOCKED_LIQUIDITY;

        token_.approve(address(hook_), type(uint256).max);
        token_.approve(address(donateRouter_), type(uint256).max);
        token_.approve(address(swapRouter_), type(uint256).max);
        weth_.approve(address(hook_), type(uint256).max);
        weth_.approve(address(donateRouter_), type(uint256).max);
        weth_.approve(address(swapRouter_), type(uint256).max);
    }

    function donateToken(uint256 amountSeed) external {
        uint256 amount = _boundedBalanceAmount(TOKEN.balanceOf(address(this)), amountSeed, MAX_TOKEN_ACTION);
        if (amount == 0) return;
        HOOK.donatePOL(amount, 0);
        _observeLiquidity();
    }

    function donateWeth(uint256 amountSeed) external {
        uint256 amount = _boundedBalanceAmount(WETH.balanceOf(address(this)), amountSeed, MAX_WETH_ACTION);
        if (amount == 0) return;
        HOOK.donatePOL(0, amount);
        _observeLiquidity();
    }

    function swapExactInput(uint256 directionSeed, uint256 amountSeed) external {
        bool tokenToWeth = directionSeed % 2 == 0;
        uint256 balance = tokenToWeth ? TOKEN.balanceOf(address(this)) : WETH.balanceOf(address(this));
        uint256 ceiling = tokenToWeth ? 1_000 ether : 0.1 ether;
        uint256 amount = _boundedBalanceAmount(balance / 2, amountSeed, ceiling);
        if (amount == 0) return;

        bool zeroForOne = tokenToWeth == tokenIsCurrency0;
        SWAP_ROUTER.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // The handler bounds `amount` to at most 1,000 ether, so this cast cannot truncate.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            IPoolSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _observeLiquidity();
    }

    function swapExactOutput(uint256 directionSeed, uint256 amountSeed) external {
        bool tokenToWeth = directionSeed % 2 == 0;
        uint256 inputBalance = tokenToWeth ? TOKEN.balanceOf(address(this)) : WETH.balanceOf(address(this));
        if (inputBalance == 0) return;
        uint256 ceiling = tokenToWeth ? 0.01 ether : 100 ether;
        uint256 amount = bound(amountSeed, 1, ceiling);
        bool zeroForOne = tokenToWeth == tokenIsCurrency0;

        SWAP_ROUTER.swap(
            canonicalKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // The handler bounds `amount` to at most 100 ether, so this cast cannot truncate.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            IPoolSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _observeLiquidity();
    }

    function donatePositionFees(uint256 currencySeed, uint256 amountSeed) external {
        bool donateTokenSide = currencySeed % 2 == 0;
        uint256 balance = donateTokenSide ? TOKEN.balanceOf(address(this)) : WETH.balanceOf(address(this));
        uint256 ceiling = donateTokenSide ? MAX_TOKEN_ACTION : MAX_WETH_ACTION;
        uint256 amount = _boundedBalanceAmount(balance, amountSeed, ceiling);
        if (amount == 0) return;

        uint256 amount0 = donateTokenSide == tokenIsCurrency0 ? amount : 0;
        uint256 amount1 = donateTokenSide == tokenIsCurrency0 ? 0 : amount;
        DONATE_ROUTER.donate(canonicalKey, amount0, amount1, "");
        _observeLiquidity();
    }

    function compound() external {
        HOOK.compoundPOL();
        _observeLiquidity();
    }

    function _boundedBalanceAmount(uint256 balance, uint256 seed, uint256 ceiling) private pure returns (uint256) {
        uint256 maximum = balance < ceiling ? balance : ceiling;
        return maximum == 0 ? 0 : bound(seed, 1, maximum);
    }

    function _observeLiquidity() private {
        uint128 current = HOOK.lockedLiquidity();
        if (current < lastLockedLiquidity) liquidityDecreased = true;
        lastLockedLiquidity = current;
        ++successfulActions;
    }
}

contract POLAccountingInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;

    uint160 private constant REQUIRED_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 private constant REQUIRED_WETH = 30 ether;
    uint256 private constant TOKEN_PER_WETH_WAD = 10_000 ether;
    int24 private constant TICK_SPACING = 60;

    WETH9 private weth;
    ActivationToken private token;
    CrottoSwapFeeHook private hook;
    POLAccountingHandler private handler;
    PoolKey private canonicalKey;
    PoolId private canonicalId;

    function setUp() public {
        IV4TestDeployment v4 = IV4TestDeployment(_deployArtifact("out/V4TestDeployment.sol/V4TestDeployment.json"));
        weth = new WETH9();
        CrottoHookController controller = new CrottoHookController(address(weth));

        address expectedToken = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory constructorArgs = abi.encode(
            v4.manager(),
            address(controller),
            expectedToken,
            address(weth),
            TICK_SPACING,
            TOKEN_PER_WETH_WAD,
            uint16(100)
        );
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(CrottoSwapFeeHook).creationCode, constructorArgs);

        token = new ActivationToken(address(this), address(controller), expectedHook);
        hook = new CrottoSwapFeeHook{salt: salt}(
            v4.manager(), address(controller), address(token), address(weth), TICK_SPACING, TOKEN_PER_WETH_WAD, 100
        );
        controller.setHook(address(hook), address(token));
        controller.setHookConfiguration(_configuration());

        canonicalKey = LibCanonicalPool.key(address(token), address(weth), address(hook), TICK_SPACING);
        canonicalId = canonicalKey.toId();
        _mintWeth(REQUIRED_WETH + 1_000 ether);
        assertTrue(weth.transfer(address(controller), REQUIRED_WETH));
        controller.initialize(
            canonicalKey,
            LibCanonicalPool.sqrtPriceX96(address(token), address(weth), TOKEN_PER_WETH_WAD),
            REQUIRED_WETH * 10_000,
            REQUIRED_WETH
        );

        handler = new POLAccountingHandler(
            hook, token, weth, IPoolDonateRouter(v4.donateRouter()), IPoolSwapRouter(v4.swapRouter()), canonicalKey
        );
        assertTrue(token.transfer(address(handler), 5_000_000 ether));
        assertTrue(weth.transfer(address(handler), 1_000 ether));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = POLAccountingHandler.donateToken.selector;
        selectors[1] = POLAccountingHandler.donateWeth.selector;
        selectors[2] = POLAccountingHandler.swapExactInput.selector;
        selectors[3] = POLAccountingHandler.swapExactOutput.selector;
        selectors[4] = POLAccountingHandler.donatePositionFees.selector;
        selectors[5] = POLAccountingHandler.compound.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_PendingBalancesRemainSolventByCurrency() public view {
        _assertPendingSolvent(address(token));
        _assertPendingSolvent(address(weth));
    }

    function invariant_LockedLiquidityNeverDecreases() public view {
        assertFalse(handler.liquidityDecreased());
        assertGe(hook.lockedLiquidity(), handler.INITIAL_LOCKED_LIQUIDITY());
        assertEq(hook.lockedLiquidity(), handler.lastLockedLiquidity());
    }

    function invariant_CanonicalPoolIdentityAndInitializationRemainFixed() public view {
        assertTrue(hook.poolInitialized());
        assertEq(PoolId.unwrap(hook.canonicalPoolId()), PoolId.unwrap(canonicalId));
        assertEq(PoolId.unwrap(hook.canonicalPoolKey().toId()), PoolId.unwrap(canonicalId));
        assertEq(hook.canonicalPoolKey().fee, 0);
    }

    function _assertPendingSolvent(address asset) private view {
        Currency currency = Currency.wrap(asset);
        uint256 pending = hook.pendingPermanentLiquidity(currency);
        assertEq(hook.totalPendingPermanentLiquidity(currency), pending);
        assertGe(IERC20(asset).balanceOf(address(hook)), pending);
    }

    function _mintWeth(uint256 amount) private {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
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
