// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IActivationToken} from "../../src/interfaces/IActivationToken.sol";
import {ActivationToken} from "../../src/token/ActivationToken.sol";

contract ActivationTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event GenesisTreasuryMinted(address indexed treasuryReceiver, uint256 amount);
    event PlayerRewardMinted(address indexed receiver, uint256 amount);
    event BootstrapPOLMinted(address indexed receiver, uint256 amount);

    address private constant TREASURY = address(0xA11CE);
    address private constant DIAMOND = address(0xD1A);
    address private constant HOOK = address(0xB00C);
    address private constant PLAYER = address(0xB0B);
    uint256 private constant GENESIS_SUPPLY = 10_000_000 ether;

    ActivationToken private token;

    function setUp() public {
        token = new ActivationToken(TREASURY, DIAMOND, HOOK);
    }

    function test_ConstructorSetsMetadataAuthoritiesAndGenesisSupply() public view {
        assertEq(token.name(), "Crotto");
        assertEq(token.symbol(), "CROTTO");
        assertEq(token.decimals(), 18);
        assertEq(token.crottoDiamond(), DIAMOND);
        assertEq(token.canonicalHook(), HOOK);
        assertEq(token.GENESIS_TREASURY_SUPPLY(), GENESIS_SUPPLY);
        assertEq(token.balanceOf(TREASURY), GENESIS_SUPPLY);
        assertEq(token.totalSupply(), GENESIS_SUPPLY);
        assertFalse(token.bootstrapMintExecuted());
    }

    function test_ConstructorEmitsGenesisSupplyEvents() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), TREASURY, GENESIS_SUPPLY);
        vm.expectEmit(true, false, false, true);
        emit GenesisTreasuryMinted(TREASURY, GENESIS_SUPPLY);

        new ActivationToken(TREASURY, DIAMOND, HOOK);
    }

    function test_ConstructorRejectsZeroTreasury() public {
        vm.expectRevert(IActivationToken.ZeroAddress.selector);
        new ActivationToken(address(0), DIAMOND, HOOK);
    }

    function test_ConstructorRejectsZeroDiamond() public {
        vm.expectRevert(IActivationToken.ZeroAddress.selector);
        new ActivationToken(TREASURY, address(0), HOOK);
    }

    function test_ConstructorRejectsZeroHook() public {
        vm.expectRevert(IActivationToken.ZeroAddress.selector);
        new ActivationToken(TREASURY, DIAMOND, address(0));
    }

    function test_ConstructorAcceptsPrecomputedAuthorityAddresses() public {
        address futureDiamond = address(0x1111);
        address futureHook = address(0x2222);

        ActivationToken preconfigured = new ActivationToken(TREASURY, futureDiamond, futureHook);

        assertEq(preconfigured.crottoDiamond(), futureDiamond);
        assertEq(preconfigured.canonicalHook(), futureHook);
        assertEq(futureDiamond.code.length, 0);
        assertEq(futureHook.code.length, 0);
    }

    function test_DiamondMintsRepeatablePlayerRewards() public {
        uint256 firstAmount = 12 ether;
        uint256 secondAmount = 7 ether;

        vm.startPrank(DIAMOND);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(0), PLAYER, firstAmount);
        vm.expectEmit(true, false, false, true, address(token));
        emit PlayerRewardMinted(PLAYER, firstAmount);
        token.mintPlayerReward(PLAYER, firstAmount);
        token.mintPlayerReward(PLAYER, secondAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(PLAYER), firstAmount + secondAmount);
        assertEq(token.totalSupply(), GENESIS_SUPPLY + firstAmount + secondAmount);
    }

    function test_PlayerMintRejectsUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IActivationToken.UnauthorizedPlayerMinter.selector, PLAYER));
        vm.prank(PLAYER);
        token.mintPlayerReward(PLAYER, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(IActivationToken.UnauthorizedPlayerMinter.selector, HOOK));
        vm.prank(HOOK);
        token.mintPlayerReward(PLAYER, 1 ether);
    }

    function test_PlayerMintRejectsZeroReceiverAndAmount() public {
        vm.startPrank(DIAMOND);
        vm.expectRevert(IActivationToken.ZeroAddress.selector);
        token.mintPlayerReward(address(0), 1 ether);
        vm.expectRevert(IActivationToken.ZeroAmount.selector);
        token.mintPlayerReward(PLAYER, 0);
        vm.stopPrank();
    }

    function test_HookMintsBootstrapSupplyOnce() public {
        uint256 amount = 2_500 ether;

        vm.startPrank(HOOK);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(0), address(token), amount);
        vm.expectEmit(true, false, false, true, address(token));
        emit BootstrapPOLMinted(address(token), amount);
        token.mintBootstrapPOL(address(token), amount);

        vm.expectRevert(IActivationToken.BootstrapMintAlreadyExecuted.selector);
        token.mintBootstrapPOL(PLAYER, 1 ether);
        vm.stopPrank();

        assertTrue(token.bootstrapMintExecuted());
        assertEq(token.balanceOf(address(token)), amount);
        assertEq(token.totalSupply(), GENESIS_SUPPLY + amount);
    }

    function test_BootstrapMintRejectsUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IActivationToken.UnauthorizedBootstrapMinter.selector, PLAYER));
        vm.prank(PLAYER);
        token.mintBootstrapPOL(PLAYER, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(IActivationToken.UnauthorizedBootstrapMinter.selector, DIAMOND));
        vm.prank(DIAMOND);
        token.mintBootstrapPOL(PLAYER, 1 ether);
    }

    function test_InvalidBootstrapMintDoesNotConsumeOneShot() public {
        vm.startPrank(HOOK);
        vm.expectRevert(IActivationToken.ZeroAddress.selector);
        token.mintBootstrapPOL(address(0), 1 ether);
        vm.expectRevert(IActivationToken.ZeroAmount.selector);
        token.mintBootstrapPOL(PLAYER, 0);
        assertFalse(token.bootstrapMintExecuted());

        token.mintBootstrapPOL(PLAYER, 1 ether);
        vm.stopPrank();

        assertTrue(token.bootstrapMintExecuted());
        assertEq(token.balanceOf(PLAYER), 1 ether);
    }

    function test_PlayerMintRemainsAvailableAroundBootstrapMint() public {
        vm.prank(DIAMOND);
        token.mintPlayerReward(PLAYER, 1 ether);

        vm.prank(HOOK);
        token.mintBootstrapPOL(address(token), 2 ether);

        vm.prank(DIAMOND);
        token.mintPlayerReward(PLAYER, 3 ether);

        assertEq(token.balanceOf(PLAYER), 4 ether);
        assertEq(token.balanceOf(address(token)), 2 ether);
    }

    function test_HolderBurnsOnlyOwnBalance() public {
        uint256 amount = 125 ether;
        vm.prank(TREASURY);
        assertTrue(token.transfer(PLAYER, amount));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(PLAYER, address(0), amount);
        vm.prank(PLAYER);
        token.burn(amount);

        assertEq(token.balanceOf(PLAYER), 0);
        assertEq(token.balanceOf(TREASURY), GENESIS_SUPPLY - amount);
        assertEq(token.totalSupply(), GENESIS_SUPPLY - amount);
    }

    function test_BurnRejectsZeroAndExcessBalance() public {
        vm.expectRevert(IActivationToken.ZeroAmount.selector);
        vm.prank(PLAYER);
        token.burn(0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, PLAYER, 0, 1));
        vm.prank(PLAYER);
        token.burn(1);
    }
}
