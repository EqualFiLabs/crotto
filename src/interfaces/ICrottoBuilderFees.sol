// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {BuilderApproval} from "../types/CrottoTypes.sol";

/// @notice Player-authorized Builder Fee accrual and pull-claim surface.
interface ICrottoBuilderFees {
    event BuilderApprovalSet(
        address indexed player, address indexed builder, uint16 maximumFeeBps, bool mayReceiveTicketRewards
    );
    event BuilderFeeAccrued(
        address indexed buyer,
        address indexed builder,
        uint256 indexed roundId,
        uint256 ticketCount,
        uint16 feeBps,
        uint256 amount
    );
    event BuilderFeesClaimed(address indexed builder, address indexed receiver, uint256 amount);
    event BuilderFeesSettled(uint256 indexed roundId, address indexed builder, uint256 amount);
    event TicketRewardBeneficiarySelected(
        address indexed buyer, address indexed beneficiary, uint256 indexed roundId, uint256 ticketCount
    );

    function MAX_BUILDER_FEE_BPS() external view returns (uint16);

    function approveBuilder(address builder, uint16 maximumFeeBps, bool mayReceiveTicketRewards) external;

    function revokeBuilder(address builder) external;

    function claimBuilderFees(address receiver) external returns (uint256 amount);

    function settleBuilderFees(uint256 roundId) external returns (uint256 amount);

    function builderApproval(address player, address builder) external view returns (BuilderApproval memory);

    function builderCredit(address builder) external view returns (uint256);

    function totalBuilderFeeLiability() external view returns (uint256);

    function provisionalBuilderCredit(uint256 roundId, address builder) external view returns (uint256);
}
