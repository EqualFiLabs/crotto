// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {ICrottoBuilderFees} from "../../interfaces/ICrottoBuilderFees.sol";
import {CrottoConstants} from "../../libraries/CrottoConstants.sol";
import {LibCrottoValidation} from "../../libraries/LibCrottoValidation.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibBuilderFeesStorage} from "../../libraries/storage/LibBuilderFeesStorage.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {LibRoundSettlementStorage} from "../../libraries/storage/LibRoundSettlementStorage.sol";
import {BuilderApproval, RoundStatus} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Player-controlled Builder approvals and isolated native ETH pull claims.
contract BuilderFeesFacet is CrottoFacet {
    uint16 public constant MAX_BUILDER_FEE_BPS = CrottoConstants.MAX_BUILDER_FEE_BPS;

    address private immutable _facetSelf = address(this);

    error DirectFacetCall();
    error InvalidBuilder(address builder);
    error BuilderFeeBpsExceeded(uint256 requested, uint256 maximum);
    error EmptyBuilderApproval();
    error BuilderFeeUnavailable(address builder);
    error InvalidBuilderFeeReceiver(address receiver);
    error NativeTransferFailed(address receiver, uint256 amount);
    error UnexpectedNativeDebit(uint256 expected, uint256 actual);
    error BuilderRoundNotFinalized(uint256 roundId, RoundStatus status);

    modifier onlyDiamond() {
        if (address(this) == _facetSelf) revert DirectFacetCall();
        _;
    }

    function approveBuilder(address builder, uint16 maximumFeeBps, bool mayReceiveTicketRewards)
        external
        onlyDiamond
        nonReentrant
    {
        if (builder == address(0)) revert InvalidBuilder(builder);
        if (maximumFeeBps > MAX_BUILDER_FEE_BPS) {
            revert BuilderFeeBpsExceeded(maximumFeeBps, MAX_BUILDER_FEE_BPS);
        }
        if (maximumFeeBps == 0 && !mayReceiveTicketRewards) revert EmptyBuilderApproval();

        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (LibCrottoValidation.isProtocolAddress(builder, governance.immutableConfiguration)) {
            revert InvalidBuilder(builder);
        }

        LibBuilderFeesStorage.layout().approvals[msg.sender][builder] =
            BuilderApproval({maximumFeeBps: maximumFeeBps, mayReceiveTicketRewards: mayReceiveTicketRewards});
        emit ICrottoBuilderFees.BuilderApprovalSet(msg.sender, builder, maximumFeeBps, mayReceiveTicketRewards);
    }

    function revokeBuilder(address builder) external onlyDiamond nonReentrant {
        if (builder == address(0)) revert InvalidBuilder(builder);
        delete LibBuilderFeesStorage.layout().approvals[msg.sender][builder];
        emit ICrottoBuilderFees.BuilderApprovalSet(msg.sender, builder, 0, false);
    }

    function claimBuilderFees(address receiver) external onlyDiamond nonReentrant returns (uint256 amount) {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        if (
            receiver == address(0) || LibCrottoValidation.isProtocolAddress(receiver, governance.immutableConfiguration)
        ) revert InvalidBuilderFeeReceiver(receiver);

        LibBuilderFeesStorage.Layout storage state = LibBuilderFeesStorage.layout();
        amount = state.credits[msg.sender];
        if (amount == 0) revert BuilderFeeUnavailable(msg.sender);

        state.credits[msg.sender] = 0;
        state.totalNativeEthLiability -= amount;

        uint256 balanceBefore = address(this).balance;
        bool success = _sendNative(receiver, amount);
        if (!success) revert NativeTransferFailed(receiver, amount);
        uint256 balanceAfter = address(this).balance;
        uint256 actualDebit = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        if (actualDebit != amount) revert UnexpectedNativeDebit(amount, actualDebit);

        LibOperationsAccounting.enforceNativeSolvency();
        emit ICrottoBuilderFees.BuilderFeesClaimed(msg.sender, receiver, amount);
    }

    function settleBuilderFees(uint256 roundId) external onlyDiamond nonReentrant returns (uint256 amount) {
        RoundStatus status = LibLotteryStorage.layout().rounds[roundId].status;
        if (roundId == 0 || status != RoundStatus.Finalized) revert BuilderRoundNotFinalized(roundId, status);

        LibRoundSettlementStorage.Layout storage settlements = LibRoundSettlementStorage.layout();
        amount = settlements.provisionalBuilderCreditEth[roundId][msg.sender];
        if (amount == 0) revert BuilderFeeUnavailable(msg.sender);
        settlements.provisionalBuilderCreditEth[roundId][msg.sender] = 0;

        LibBuilderFeesStorage.Layout storage builders = LibBuilderFeesStorage.layout();
        builders.provisionalNativeEthLiability -= amount;
        builders.credits[msg.sender] += amount;
        emit ICrottoBuilderFees.BuilderFeesSettled(roundId, msg.sender, amount);
    }

    function builderApproval(address player, address builder) external view returns (BuilderApproval memory) {
        return LibBuilderFeesStorage.layout().approvals[player][builder];
    }

    function builderCredit(address builder) external view returns (uint256) {
        return LibBuilderFeesStorage.layout().credits[builder];
    }

    function totalBuilderFeeLiability() external view returns (uint256) {
        return LibBuilderFeesStorage.layout().totalNativeEthLiability;
    }

    function provisionalBuilderCredit(uint256 roundId, address builder) external view returns (uint256) {
        if (LibLotteryStorage.layout().rounds[roundId].status == RoundStatus.Expired) return 0;
        return LibRoundSettlementStorage.layout().provisionalBuilderCreditEth[roundId][builder];
    }

    /// @dev Ignores return data so a recipient cannot force an unbounded copy into Diamond memory.
    function _sendNative(address receiver, uint256 amount) private returns (bool success) {
        assembly ("memory-safe") {
            success := call(gas(), receiver, amount, 0, 0, 0, 0)
        }
    }
}
