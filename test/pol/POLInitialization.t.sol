// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "@chainlink/contracts/src/v0.8/vendor/canonical-weth/WETH9.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CrottoDiamond} from "../../src/diamond/CrottoDiamond.sol";
import {POLInitializationFacet} from "../../src/diamond/facets/POLInitializationFacet.sol";
import {IDiamondCut} from "../../src/interfaces/diamond/IDiamondCut.sol";
import {IPOLInitialization} from "../../src/interfaces/IPOLInitialization.sol";
import {LibCanonicalPool} from "../../src/libraries/LibCanonicalPool.sol";
import {LibGovernanceStorage} from "../../src/libraries/storage/LibGovernanceStorage.sol";
import {LibPOLStorage} from "../../src/libraries/storage/LibPOLStorage.sol";
import {ImmutableConfiguration, POLAccountingView} from "../../src/types/CrottoTypes.sol";

contract POLInitializationStateFacet {
    function configure(ImmutableConfiguration calldata configuration, uint256 bootstrapWeth) external {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        governance.immutableConfiguration = configuration;
        governance.immutableConfigurationInitialized = true;
        LibPOLStorage.layout().bootstrapWeth = bootstrapWeth;
    }

    function rawState()
        external
        view
        returns (uint256 bootstrapWeth, bool initialized, bool authorized, PoolId poolId)
    {
        LibPOLStorage.Layout storage state = LibPOLStorage.layout();
        return (state.bootstrapWeth, state.initialized, state.initializationAuthorized, state.canonicalPoolId);
    }
}

contract CanonicalPriceHarness {
    function bootstrapTokenAmount(uint256 requiredWeth, uint256 ratio) external pure returns (uint256) {
        return LibCanonicalPool.bootstrapTokenAmount(requiredWeth, ratio);
    }

    function sqrtPriceX96(address token, address weth, uint256 ratio) external pure returns (uint160) {
        return LibCanonicalPool.sqrtPriceX96(token, weth, ratio);
    }
}

contract POLInitializationHookProbe {
    using PoolIdLibrary for PoolKey;

    enum FailureStage {
        None,
        Funding,
        Mint,
        Pool,
        Seed
    }

    error InitializationStageFailed(FailureStage stage);

    address public immutable diamond;
    address public immutable weth;
    FailureStage public failureStage;
    bool public wrongPool;
    bool public zeroLiquidity;
    bool public authorizationObserved;
    uint256 public tokenAmountObserved;
    uint256 public wethAmountObserved;
    uint160 public sqrtPriceObserved;
    PoolKey private storedKey;

    constructor(address diamond_, address weth_) {
        diamond = diamond_;
        weth = weth_;
    }

    function setFailure(FailureStage stage, bool wrongPool_, bool zeroLiquidity_) external {
        failureStage = stage;
        wrongPool = wrongPool_;
        zeroLiquidity = zeroLiquidity_;
    }

    function initializeCanonicalPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint256 tokenAmount,
        uint256 wethAmount
    ) external returns (PoolId poolId, uint128 liquidity) {
        require(msg.sender == diamond);
        authorizationObserved = IPOLInitialization(diamond).polInitializationAuthorized();
        require(authorizationObserved);
        if (failureStage != FailureStage.None) revert InitializationStageFailed(failureStage);
        require(IERC20(weth).balanceOf(address(this)) == wethAmount);

        storedKey = key;
        tokenAmountObserved = tokenAmount;
        wethAmountObserved = wethAmount;
        sqrtPriceObserved = sqrtPriceX96;
        poolId = wrongPool ? PoolId.wrap(bytes32(uint256(1))) : key.toId();
        liquidity = zeroLiquidity ? 0 : 123;
    }

    function canonicalPoolKey() external view returns (PoolKey memory) {
        return storedKey;
    }

    function pendingPermanentLiquidity(Currency currency) external view returns (uint256) {
        return Currency.unwrap(currency) == weth ? 17 : 11;
    }

    function lockedLiquidity() external pure returns (uint128) {
        return 123;
    }
}

contract POLInitializationTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant REQUIRED_WETH = 30 ether;
    uint256 private constant EXCESS_WETH = 7 ether;
    uint256 private constant TOKEN_PER_WETH_WAD = 10_000 ether;

    address private caller = makeAddr("caller");
    address private token = address(0x1111);
    WETH9 private weth;
    CrottoDiamond private diamond;
    IPOLInitialization private initialization;
    POLInitializationStateFacet private state;
    POLInitializationHookProbe private hook;

    event POLInitialized(
        address indexed caller, PoolId indexed poolId, uint256 bootstrapWeth, uint256 bootstrapToken, uint128 liquidity
    );

    function setUp() public {
        weth = new WETH9();

        // The hook needs the final Diamond address, while the Diamond config needs the hook address.
        address predictedDiamond = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        hook = new POLInitializationHookProbe(predictedDiamond, address(weth));
        POLInitializationFacet initializationFacet = new POLInitializationFacet();
        POLInitializationStateFacet stateFacet = new POLInitializationStateFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = _facetCut(address(initializationFacet), _initializationSelectors());
        cuts[1] = _facetCut(address(stateFacet), _stateSelectors());
        diamond = new CrottoDiamond(address(this), cuts, address(0), "");
        assertEq(address(diamond), predictedDiamond);

        initialization = IPOLInitialization(address(diamond));
        state = POLInitializationStateFacet(address(diamond));
        _configure(REQUIRED_WETH + EXCESS_WETH);
        _fundDiamond(REQUIRED_WETH + EXCESS_WETH);
    }

    function test_AnyoneInitializesAtThresholdWithExactMintAndExcessPending() public {
        uint256 expectedToken = REQUIRED_WETH * 10_000;
        PoolKey memory expectedKey = LibCanonicalPool.key(token, address(weth), address(hook), 60);

        assertTrue(initialization.canInitializePOL());
        vm.expectEmit(true, true, false, true, address(diamond));
        emit POLInitialized(caller, expectedKey.toId(), REQUIRED_WETH + EXCESS_WETH, expectedToken, 123);
        vm.prank(caller);
        (PoolId poolId, uint128 liquidity) = initialization.initializePOL();

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(expectedKey.toId()));
        assertEq(liquidity, 123);
        assertTrue(hook.authorizationObserved());
        assertEq(hook.tokenAmountObserved(), expectedToken);
        assertEq(hook.wethAmountObserved(), REQUIRED_WETH + EXCESS_WETH);
        assertEq(weth.balanceOf(address(hook)), REQUIRED_WETH + EXCESS_WETH);
        assertEq(weth.balanceOf(address(diamond)), 0);
        assertFalse(initialization.canInitializePOL());
        assertTrue(initialization.polInitialized());
        assertFalse(initialization.polInitializationAuthorized());
        assertEq(initialization.bootstrapPolWeth(), 0);

        POLAccountingView memory accounting = initialization.polAccounting();
        assertTrue(accounting.initialized);
        assertEq(PoolId.unwrap(accounting.poolId), PoolId.unwrap(poolId));
        assertEq(accounting.lockedLiquidity, 123);
        assertEq(accounting.pendingToken, 11);
        assertEq(accounting.pendingWeth, 17);
    }

    function test_ThresholdBoundaryAndDuplicateInitialization() public {
        _configure(REQUIRED_WETH - 1);
        assertFalse(initialization.canInitializePOL());
        vm.expectRevert(
            abi.encodeWithSelector(
                POLInitializationFacet.InsufficientBootstrapWeth.selector, REQUIRED_WETH - 1, REQUIRED_WETH
            )
        );
        initialization.initializePOL();

        _configure(REQUIRED_WETH);
        initialization.initializePOL();
        vm.expectRevert(POLInitializationFacet.POLAlreadyInitialized.selector);
        initialization.initializePOL();
    }

    function test_GenesisPriceInvertsWithCurrencyOrdering() public {
        CanonicalPriceHarness harness = new CanonicalPriceHarness();
        uint160 tokenFirst = harness.sqrtPriceX96(address(1), address(2), 4 ether);
        uint160 wethFirst = harness.sqrtPriceX96(address(2), address(1), 4 ether);

        assertEq(uint256(tokenFirst) * uint256(wethFirst) / (1 << 96), 1 << 96);
        assertEq(harness.bootstrapTokenAmount(3 ether, 4 ether), 12 ether);
    }

    function test_RevertingInitializationStagesRollBackEveryAccountingClass() public {
        for (uint256 i = 1; i <= uint256(POLInitializationHookProbe.FailureStage.Seed); ++i) {
            hook.setFailure(POLInitializationHookProbe.FailureStage(i), false, false);
            vm.expectRevert(
                abi.encodeWithSelector(
                    POLInitializationHookProbe.InitializationStageFailed.selector,
                    POLInitializationHookProbe.FailureStage(i)
                )
            );
            initialization.initializePOL();
            _assertPreInitializationState();
        }
    }

    function test_InvalidPoolResultAndEmptySeedRollBack() public {
        hook.setFailure(POLInitializationHookProbe.FailureStage.None, true, false);
        PoolId expectedPool = LibCanonicalPool.key(token, address(weth), address(hook), 60).toId();
        vm.expectRevert(
            abi.encodeWithSelector(
                POLInitializationFacet.UnexpectedCanonicalPool.selector, expectedPool, PoolId.wrap(bytes32(uint256(1)))
            )
        );
        initialization.initializePOL();
        _assertPreInitializationState();

        hook.setFailure(POLInitializationHookProbe.FailureStage.None, false, true);
        vm.expectRevert(POLInitializationFacet.EmptyInitialLiquidity.selector);
        initialization.initializePOL();
        _assertPreInitializationState();
    }

    function _assertPreInitializationState() private view {
        (uint256 bootstrapWeth, bool initialized, bool authorized, PoolId poolId) = state.rawState();
        assertEq(bootstrapWeth, REQUIRED_WETH + EXCESS_WETH);
        assertFalse(initialized);
        assertFalse(authorized);
        assertEq(PoolId.unwrap(poolId), bytes32(0));
        assertEq(weth.balanceOf(address(diamond)), REQUIRED_WETH + EXCESS_WETH);
        assertEq(weth.balanceOf(address(hook)), 0);
    }

    function _configure(uint256 bootstrapWeth) private {
        ImmutableConfiguration memory config = ImmutableConfiguration({
            activationToken: token,
            rewardNFT: address(0x2222),
            weth: address(weth),
            vrfWrapper: address(0x3333),
            uniswapV4PoolManager: address(0x4444),
            canonicalHook: address(hook),
            rewardNFTMaxSupply: 10_000,
            vaultPrice: 1 ether,
            requiredBootstrapWeth: REQUIRED_WETH,
            initialTokenPerWethWad: TOKEN_PER_WETH_WAD,
            maxCombinedHookFeeBps: 100,
            canonicalTickSpacing: 60,
            vrfCallbackGasLimit: 500_000,
            vrfRequestConfirmations: 3
        });
        state.configure(config, bootstrapWeth);
    }

    function _fundDiamond(uint256 amount) private {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(diamond), amount);
    }

    function _facetCut(address facet, bytes4[] memory selectors)
        private
        pure
        returns (IDiamondCut.FacetCut memory cut)
    {
        cut = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _initializationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IPOLInitialization.initializePOL.selector;
        selectors[1] = IPOLInitialization.canInitializePOL.selector;
        selectors[2] = IPOLInitialization.polInitialized.selector;
        selectors[3] = IPOLInitialization.polInitializationAuthorized.selector;
        selectors[4] = IPOLInitialization.bootstrapPolWeth.selector;
        selectors[5] = IPOLInitialization.requiredBootstrapWeth.selector;
        selectors[6] = IPOLInitialization.bootstrapTokenMintAmount.selector;
        selectors[7] = IPOLInitialization.initialTokenPerWethWad.selector;
        selectors[8] = IPOLInitialization.canonicalPoolId.selector;
        selectors[9] = IPOLInitialization.polAccounting.selector;
    }

    function _stateSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = POLInitializationStateFacet.configure.selector;
        selectors[1] = POLInitializationStateFacet.rawState.selector;
    }
}
