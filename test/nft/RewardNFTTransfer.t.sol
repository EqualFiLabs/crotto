// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IRewardNFT} from "../../src/interfaces/IRewardNFT.sol";
import {RewardNFT} from "../../src/token/RewardNFT.sol";

contract RewardNFTCallbackDiamond {
    error SettlementFailed();

    IRewardNFT public rewardNFT;
    uint256 public callbackCount;
    address public callbackFrom;
    address public callbackTo;
    uint256 public callbackTokenId;
    address public ownerDuringCallback;
    bool public failSettlement;

    function configure(IRewardNFT rewardNft_) external {
        rewardNFT = rewardNft_;
    }

    function mint(address receiver) external returns (uint256 tokenId) {
        return rewardNFT.mint(receiver);
    }

    function onRewardNFTTransfer(address from, address to, uint256 tokenId) external {
        if (failSettlement) revert SettlementFailed();
        ++callbackCount;
        callbackFrom = from;
        callbackTo = to;
        callbackTokenId = tokenId;
        ownerDuringCallback = rewardNFT.ownerOf(tokenId);
    }

    function setFailSettlement(bool failSettlement_) external {
        failSettlement = failSettlement_;
    }
}

contract RewardNFTTransferHarness is RewardNFT {
    constructor(address crottoDiamond_, uint256 maxSupply_) RewardNFT(crottoDiamond_, maxSupply_) {}

    function exposedTransfer(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function exposedSafeTransfer(address from, address to, uint256 tokenId, bytes calldata data) external {
        _safeTransfer(from, to, tokenId, data);
    }
}

contract RecordingRewardNFTReceiver is IERC721Receiver {
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

contract RejectingTransferReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(0);
    }
}

contract RewardNFTTransferTest is Test {
    uint256 private constant MAX_SUPPLY = 100;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant OPERATOR = address(0x0F3);

    RewardNFTCallbackDiamond private diamond;
    RewardNFTTransferHarness private rewardNFT;

    function setUp() public {
        diamond = new RewardNFTCallbackDiamond();
        rewardNFT = new RewardNFTTransferHarness(address(diamond), MAX_SUPPLY);
        diamond.configure(rewardNFT);
        diamond.mint(ALICE);
    }

    function test_TransferFromCallsDiamondBeforeOwnershipChanges() public {
        vm.prank(ALICE);
        rewardNFT.transferFrom(ALICE, BOB, 1);

        _assertCallback(ALICE, BOB, 1, ALICE, 1);
        assertEq(rewardNFT.ownerOf(1), BOB);
    }

    function test_ApprovedOperatorCallsCallbackExactlyOnce() public {
        vm.prank(ALICE);
        rewardNFT.approve(OPERATOR, 1);

        vm.prank(OPERATOR);
        rewardNFT.transferFrom(ALICE, BOB, 1);

        _assertCallback(ALICE, BOB, 1, ALICE, 1);
        assertEq(rewardNFT.getApproved(1), address(0));
    }

    function test_SafeTransferWithoutDataCallsCallbackExactlyOnce() public {
        RecordingRewardNFTReceiver receiver = new RecordingRewardNFTReceiver();

        vm.prank(ALICE);
        rewardNFT.safeTransferFrom(ALICE, address(receiver), 1);

        _assertCallback(ALICE, address(receiver), 1, ALICE, 1);
        assertEq(receiver.operator(), ALICE);
        assertEq(receiver.from(), ALICE);
        assertEq(receiver.tokenId(), 1);
        assertEq(receiver.data(), bytes(""));
    }

    function test_SafeTransferWithDataCallsCallbackExactlyOnce() public {
        RecordingRewardNFTReceiver receiver = new RecordingRewardNFTReceiver();
        bytes memory data = hex"c001c0de";

        vm.prank(ALICE);
        rewardNFT.safeTransferFrom(ALICE, address(receiver), 1, data);

        _assertCallback(ALICE, address(receiver), 1, ALICE, 1);
        assertEq(receiver.data(), data);
    }

    function test_InternalTransferCannotBypassCallback() public {
        rewardNFT.exposedTransfer(ALICE, BOB, 1);

        _assertCallback(ALICE, BOB, 1, ALICE, 1);
        assertEq(rewardNFT.ownerOf(1), BOB);
    }

    function test_InternalSafeTransferCannotBypassCallback() public {
        RecordingRewardNFTReceiver receiver = new RecordingRewardNFTReceiver();
        bytes memory data = hex"beef";

        rewardNFT.exposedSafeTransfer(ALICE, address(receiver), 1, data);

        _assertCallback(ALICE, address(receiver), 1, ALICE, 1);
        assertEq(receiver.data(), data);
    }

    function test_SelfTransferStillCallsCallback() public {
        vm.prank(ALICE);
        rewardNFT.transferFrom(ALICE, ALICE, 1);

        _assertCallback(ALICE, ALICE, 1, ALICE, 1);
        assertEq(rewardNFT.ownerOf(1), ALICE);
    }

    function test_UnauthorizedTransferDoesNotCallCallback() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, OPERATOR, 1));
        vm.prank(OPERATOR);
        rewardNFT.transferFrom(ALICE, BOB, 1);

        assertEq(diamond.callbackCount(), 0);
        assertEq(rewardNFT.ownerOf(1), ALICE);
    }

    function test_CallbackFailurePreservesOwnershipAndApproval() public {
        vm.prank(ALICE);
        rewardNFT.approve(OPERATOR, 1);
        diamond.setFailSettlement(true);

        vm.expectRevert(RewardNFTCallbackDiamond.SettlementFailed.selector);
        vm.prank(OPERATOR);
        rewardNFT.transferFrom(ALICE, BOB, 1);

        assertEq(diamond.callbackCount(), 0);
        assertEq(rewardNFT.ownerOf(1), ALICE);
        assertEq(rewardNFT.getApproved(1), OPERATOR);
        assertEq(rewardNFT.mintedSupply(), 1);
    }

    function test_ReceiverFailureRollsBackCallbackAndOwnership() public {
        RejectingTransferReceiver receiver = new RejectingTransferReceiver();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        vm.prank(ALICE);
        rewardNFT.safeTransferFrom(ALICE, address(receiver), 1);

        assertEq(diamond.callbackCount(), 0);
        assertEq(rewardNFT.ownerOf(1), ALICE);
        assertEq(rewardNFT.mintedSupply(), 1);
    }

    function test_MintDoesNotInvokeTransferCallback() public view {
        assertEq(diamond.callbackCount(), 0);
        assertEq(rewardNFT.ownerOf(1), ALICE);
    }

    function test_TransferRejectsUnavailableDiamondCode() public {
        address futureDiamond = address(0xD1A);
        RewardNFT preconfigured = new RewardNFT(futureDiamond, 1);
        vm.prank(futureDiamond);
        preconfigured.mint(ALICE);

        vm.expectRevert(abi.encodeWithSelector(IRewardNFT.DiamondCallbackUnavailable.selector, futureDiamond));
        vm.prank(ALICE);
        preconfigured.transferFrom(ALICE, BOB, 1);

        assertEq(preconfigured.ownerOf(1), ALICE);
    }

    function test_CompiledNftExcludesAdministrativeAndBurnControls() public view {
        // The path is fixed by this test and access is read-only to generated Foundry output.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory artifact = vm.readFile("out/RewardNFT.sol/RewardNFT.json");
        string[] memory signatures = vm.parseJsonKeys(artifact, ".methodIdentifiers");
        assertEq(signatures.length, 17);

        string[12] memory forbidden = [
            "burn(uint256)",
            "publicMint(address)",
            "safeMint(address)",
            "ownerMint(address)",
            "setBaseURI(string)",
            "setMaxSupply(uint256)",
            "setCrottoDiamond(address)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()"
        ];

        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(_contains(signatures, forbidden[i]), forbidden[i]);
        }
    }

    function _assertCallback(address from, address to, uint256 tokenId, address ownerDuring, uint256 count)
        private
        view
    {
        assertEq(diamond.callbackCount(), count);
        assertEq(diamond.callbackFrom(), from);
        assertEq(diamond.callbackTo(), to);
        assertEq(diamond.callbackTokenId(), tokenId);
        assertEq(diamond.ownerDuringCallback(), ownerDuring);
    }

    function _contains(string[] memory values, string memory target) private pure returns (bool) {
        bytes32 targetHash = keccak256(bytes(target));
        for (uint256 i; i < values.length; ++i) {
            if (keccak256(bytes(values[i])) == targetHash) return true;
        }
        return false;
    }
}
