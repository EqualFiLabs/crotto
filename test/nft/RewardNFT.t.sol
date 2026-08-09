// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";

contract RewardNFTMintingDiamond {
    function mint(IRewardNFT rewardNFT, address receiver) external returns (uint256 tokenId) {
        return rewardNFT.mint(receiver);
    }
}

contract AcceptingRewardNFTReceiver is IERC721Receiver {
    address public operator;
    address public from;
    uint256 public tokenId;
    bytes public data;

    function onERC721Received(address operator_, address from_, uint256 tokenId_, bytes calldata data_)
        external
        returns (bytes4)
    {
        operator = operator_;
        from = from_;
        tokenId = tokenId_;
        data = data_;
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract RejectingRewardNFTReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }
}

contract RewardNFTTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    uint256 private constant MAX_SUPPLY = 10_000;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    RewardNFTMintingDiamond private diamond;
    RewardNFT private rewardNFT;

    function setUp() public {
        diamond = new RewardNFTMintingDiamond();
        rewardNFT = new RewardNFT(address(diamond), MAX_SUPPLY);
    }

    function test_ConstructorSetsImmutableIdentityWithZeroMintedSupply() public view {
        assertEq(rewardNFT.name(), "Crottos");
        assertEq(rewardNFT.symbol(), "CROTTOS");
        assertEq(rewardNFT.crottoDiamond(), address(diamond));
        assertEq(rewardNFT.maxSupply(), MAX_SUPPLY);
        assertEq(rewardNFT.mintedSupply(), 0);
        assertEq(rewardNFT.balanceOf(ALICE), 0);
    }

    function test_ConstructorRejectsZeroDiamond() public {
        vm.expectRevert(IRewardNFT.ZeroAddress.selector);
        new RewardNFT(address(0), MAX_SUPPLY);
    }

    function test_ConstructorRejectsZeroMaxSupply() public {
        vm.expectRevert(IRewardNFT.InvalidMaxSupply.selector);
        new RewardNFT(address(diamond), 0);
    }

    function test_ConstructorAcceptsPrecomputedDiamondAddress() public {
        address futureDiamond = address(0xD1A);

        RewardNFT preconfigured = new RewardNFT(futureDiamond, 1);

        assertEq(preconfigured.crottoDiamond(), futureDiamond);
        assertEq(futureDiamond.code.length, 0);
    }

    function test_SupportsStandardAndRewardNftInterfaces() public view {
        assertTrue(rewardNFT.supportsInterface(type(IERC165).interfaceId));
        assertTrue(rewardNFT.supportsInterface(type(IERC721).interfaceId));
        assertTrue(rewardNFT.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(rewardNFT.supportsInterface(type(IRewardNFT).interfaceId));
        assertFalse(rewardNFT.supportsInterface(0xffffffff));
    }

    function test_DiamondSafelyMintsOneBasedSequentialIds() public {
        vm.expectEmit(true, true, true, true, address(rewardNFT));
        emit Transfer(address(0), ALICE, 1);
        uint256 firstTokenId = diamond.mint(rewardNFT, ALICE);
        uint256 secondTokenId = diamond.mint(rewardNFT, BOB);

        assertEq(firstTokenId, 1);
        assertEq(secondTokenId, 2);
        assertEq(rewardNFT.mintedSupply(), 2);
        assertEq(rewardNFT.ownerOf(1), ALICE);
        assertEq(rewardNFT.ownerOf(2), BOB);
    }

    function test_SafeMintInvokesReceiver() public {
        AcceptingRewardNFTReceiver receiver = new AcceptingRewardNFTReceiver();

        uint256 tokenId = diamond.mint(rewardNFT, address(receiver));

        assertEq(tokenId, 1);
        assertEq(rewardNFT.ownerOf(tokenId), address(receiver));
        assertEq(receiver.operator(), address(diamond));
        assertEq(receiver.from(), address(0));
        assertEq(receiver.tokenId(), tokenId);
        assertEq(receiver.data(), bytes(""));
    }

    function test_RejectedSafeMintRollsBackSupplyAndOwnership() public {
        RejectingRewardNFTReceiver receiver = new RejectingRewardNFTReceiver();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        diamond.mint(rewardNFT, address(receiver));

        assertEq(rewardNFT.mintedSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        rewardNFT.ownerOf(1);
    }

    function test_MintRejectsUnauthorizedCaller() public {
        vm.expectRevert(abi.encodeWithSelector(IRewardNFT.UnauthorizedMinter.selector, ALICE));
        vm.prank(ALICE);
        rewardNFT.mint(ALICE);
    }

    function test_MintRejectsZeroReceiver() public {
        vm.expectRevert(IRewardNFT.ZeroAddress.selector);
        diamond.mint(rewardNFT, address(0));
    }

    function test_MintRejectsAfterMaximumSupply() public {
        RewardNFT capped = new RewardNFT(address(diamond), 2);
        diamond.mint(capped, ALICE);
        diamond.mint(capped, BOB);

        vm.expectRevert(abi.encodeWithSelector(IRewardNFT.MaxSupplyReached.selector, 2));
        diamond.mint(capped, ALICE);

        assertEq(capped.mintedSupply(), 2);
    }

    function test_TokenUriIsIntentionallyEmptyForExistingToken() public {
        diamond.mint(rewardNFT, ALICE);

        assertEq(rewardNFT.tokenURI(1), "");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        rewardNFT.tokenURI(2);
    }

    function testFuzz_DiamondMintsEverySequentialId(uint256 supply) public {
        supply = bound(supply, 1, 16);
        RewardNFT capped = new RewardNFT(address(diamond), supply);

        for (uint256 expectedTokenId = 1; expectedTokenId <= supply; ++expectedTokenId) {
            assertEq(diamond.mint(capped, ALICE), expectedTokenId);
            assertEq(capped.ownerOf(expectedTokenId), ALICE);
        }

        assertEq(capped.mintedSupply(), supply);
        assertEq(capped.balanceOf(ALICE), supply);
    }
}
