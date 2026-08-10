// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {IVRFV2PlusWrapper} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFV2PlusWrapper.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {ICrotto} from "../../interfaces/ICrotto.sol";
import {LibOperationsAccounting} from "../../libraries/LibOperationsAccounting.sol";
import {LibGovernanceStorage} from "../../libraries/storage/LibGovernanceStorage.sol";
import {LibLotteryStorage} from "../../libraries/storage/LibLotteryStorage.sol";
import {
    CallerAction,
    IgnoredFulfillmentReason,
    ImmutableConfiguration,
    RequestRecord,
    Round,
    RoundStatus
} from "../../types/CrottoTypes.sol";
import {CrottoFacet} from "../CrottoFacet.sol";

/// @notice Native-funded Chainlink VRF requests, delayed retries, and first-valid fulfillment acceptance.
contract LotteryVRFFacet is CrottoFacet {
    uint32 private constant NUM_WORDS = 1;

    error UnknownRound(uint256 roundId);
    error InvalidRandomnessRequestStatus(uint256 roundId, RoundStatus status);
    error RandomnessRetryTooEarly(uint256 roundId, uint256 elapsed, uint256 requiredDelay);
    error VrfCostExceedsMaximum(uint256 quotedCost, uint256 maximumCost);
    error InvalidVrfRequestId(uint256 requestId);
    error DuplicateVrfRequestId(uint256 requestId);
    error UnauthorizedVrfWrapper(address caller, address expectedWrapper);
    error UnexpectedNativeRequestDebit(uint256 expected, uint256 actual);

    function requestRandomness(uint256 roundId) external nonReentrant returns (uint256 requestId) {
        Round storage currentRound = _round(roundId);
        if (currentRound.status != RoundStatus.Closed) {
            revert InvalidRandomnessRequestStatus(roundId, currentRound.status);
        }

        requestId = _request(currentRound, roundId, 1, CallerAction.RandomnessRequest);
        currentRound.status = RoundStatus.VRFPending;
        emit ICrotto.RandomnessRequested(roundId, requestId, 1, msg.sender);
    }

    function retryRandomness(uint256 roundId) external nonReentrant returns (uint256 requestId) {
        Round storage currentRound = _round(roundId);
        if (currentRound.status != RoundStatus.VRFPending) {
            revert InvalidRandomnessRequestStatus(roundId, currentRound.status);
        }

        uint256 elapsed = block.timestamp - uint256(currentRound.latestRequestAt);
        uint256 requiredDelay = currentRound.config.vrfRetryDelay;
        if (elapsed < requiredDelay) revert RandomnessRetryTooEarly(roundId, elapsed, requiredDelay);

        uint32 attempt = currentRound.requestAttempts + 1;
        requestId = _request(currentRound, roundId, attempt, CallerAction.RandomnessRetry);
        emit ICrotto.RandomnessRetried(roundId, requestId, attempt, msg.sender);
    }

    /// @notice Chainlink wrapper callback; malformed or obsolete fulfillments are deliberately non-reverting.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        LibGovernanceStorage.Layout storage governance = LibGovernanceStorage.layout();
        address expectedWrapper = governance.immutableConfiguration.vrfWrapper;
        if (msg.sender != expectedWrapper) revert UnauthorizedVrfWrapper(msg.sender, expectedWrapper);

        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        RequestRecord storage request = lottery.requests[requestId];
        if (!request.known) {
            emit ICrotto.RandomnessIgnored(requestId, 0, IgnoredFulfillmentReason.UnknownRequest);
            return;
        }

        uint256 roundId = request.roundId;
        Round storage currentRound = lottery.rounds[roundId];
        if (currentRound.status == RoundStatus.RandomReady || currentRound.status == RoundStatus.Finalized) {
            emit ICrotto.RandomnessIgnored(requestId, roundId, IgnoredFulfillmentReason.RandomnessAlreadyAccepted);
            return;
        }
        if (currentRound.status != RoundStatus.VRFPending) {
            emit ICrotto.RandomnessIgnored(requestId, roundId, IgnoredFulfillmentReason.RoundNotPending);
            return;
        }
        if (randomWords.length != NUM_WORDS) {
            emit ICrotto.RandomnessIgnored(requestId, roundId, IgnoredFulfillmentReason.InvalidWordCount);
            return;
        }

        currentRound.acceptedRandomWord = randomWords[0];
        currentRound.status = RoundStatus.RandomReady;
        emit ICrotto.RandomnessAccepted(roundId, requestId, randomWords[0]);
    }

    function _request(Round storage currentRound, uint256 roundId, uint32 attempt, CallerAction action)
        private
        returns (uint256 requestId)
    {
        ImmutableConfiguration storage immutableConfig = LibGovernanceStorage.layout().immutableConfiguration;
        IVRFV2PlusWrapper wrapper = IVRFV2PlusWrapper(immutableConfig.vrfWrapper);
        uint256 requestCost = wrapper.calculateRequestPriceNative(immutableConfig.vrfCallbackGasLimit, NUM_WORDS);
        uint256 maximumCost = currentRound.config.maxVrfCost;
        if (requestCost > maximumCost) revert VrfCostExceedsMaximum(requestCost, maximumCost);

        LibOperationsAccounting.debitRequestAndCredit(
            msg.sender,
            action,
            roundId,
            attempt,
            requestCost,
            currentRound.config.requestCallerReward,
            currentRound.config.finalizationCallerReward
        );

        uint256 balanceBefore = address(this).balance;
        requestId = wrapper.requestRandomWordsInNative{value: requestCost}(
            immutableConfig.vrfCallbackGasLimit,
            immutableConfig.vrfRequestConfirmations,
            NUM_WORDS,
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
        );
        uint256 balanceAfter = address(this).balance;
        uint256 actualDebit = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        if (actualDebit != requestCost) revert UnexpectedNativeRequestDebit(requestCost, actualDebit);
        if (requestId == 0) revert InvalidVrfRequestId(requestId);

        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        if (lottery.requests[requestId].known) revert DuplicateVrfRequestId(requestId);
        lottery.requests[requestId] = RequestRecord({roundId: roundId, attempt: attempt, known: true});
        currentRound.latestRequestAt = uint64(block.timestamp);
        currentRound.requestAttempts = attempt;

        LibOperationsAccounting.enforceNativeSolvency();
    }

    function _round(uint256 roundId) private view returns (Round storage currentRound) {
        LibLotteryStorage.Layout storage lottery = LibLotteryStorage.layout();
        if (roundId == 0 || roundId > lottery.currentRoundId) revert UnknownRound(roundId);
        currentRound = lottery.rounds[roundId];
    }
}
