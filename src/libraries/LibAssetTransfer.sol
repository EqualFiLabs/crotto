// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Exact-balance-delta ERC-20 transfers for Crotto accounting boundaries.
library LibAssetTransfer {
    using SafeERC20 for IERC20;

    error UnexpectedTokenDebit(address asset, address account, uint256 expected, uint256 actual);
    error UnexpectedTokenReceipt(address asset, address account, uint256 expected, uint256 actual);

    function pullExact(address asset, address from, uint256 amount) internal {
        if (amount == 0) return;

        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(from);
        uint256 receiverBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 senderAfter = token.balanceOf(from);
        uint256 receiverAfter = token.balanceOf(address(this));

        uint256 actualDebit = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        if (actualDebit != amount) revert UnexpectedTokenDebit(asset, from, amount, actualDebit);

        uint256 actualReceipt = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (actualReceipt != amount) revert UnexpectedTokenReceipt(asset, address(this), amount, actualReceipt);
    }

    function pushExact(address asset, address receiver, uint256 amount) internal {
        if (amount == 0) return;

        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 receiverAfter = token.balanceOf(receiver);

        uint256 actualDebit = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        if (actualDebit != amount) revert UnexpectedTokenDebit(asset, address(this), amount, actualDebit);

        uint256 actualReceipt = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (actualReceipt != amount) revert UnexpectedTokenReceipt(asset, receiver, amount, actualReceipt);
    }
}
