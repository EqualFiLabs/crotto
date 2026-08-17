// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibRewardAccounting} from "./LibRewardAccounting.sol";
import {LibGovernanceStorage} from "./storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "./storage/LibLotteryStorage.sol";
import {LibPOLStorage} from "./storage/LibPOLStorage.sol";
import {LibRewardsStorage} from "./storage/LibRewardsStorage.sol";
import {LibRoundSettlementStorage} from "./storage/LibRoundSettlementStorage.sol";
import {LibTicketQueueStorage} from "./storage/LibTicketQueueStorage.sol";

/// @notice Unified solvency check for every Diamond-custodied WETH liability class.
library LibWethSolvency {
    error WethAccountingInsolvent(uint256 balance, uint256 required);

    function enforce() internal view {
        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        LibTicketQueueStorage.Layout storage queue = LibTicketQueueStorage.layout();
        uint256 required = LibLotteryStorage.layout().totalWinnerPoolWethLiability
            + LibRewardAccounting.outstanding(LibRewardsStorage.layout().wethBook) + settlements.lotteryNftWethLiability
            + LibPOLStorage.layout().bootstrapWeth + settlements.activeTicketEscrowWeth
            + settlements.expiredTicketRefundWeth + settlements.pendingBuybackWeth;
        required += queue.activeTicketEscrowWeth + queue.invalidatedTicketRefundWeth;
        uint256 balance = IERC20(LibGovernanceStorage.layout().immutableConfiguration.weth).balanceOf(address(this));
        if (balance < required) revert WethAccountingInsolvent(balance, required);
    }
}
