// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Lifecycle states for a sellout-driven Crotto round.
enum RoundStatus {
    Open,
    Closed,
    VRFPending,
    RandomReady,
    Finalized,
    Expired
}

/// @notice Permissionless lifecycle actions that earn native ETH caller credits.
enum CallerAction {
    RandomnessRequest,
    // Reserved to preserve historical caller-credit key numbering; no retry selector exists.
    RandomnessRetry,
    Finalization,
    Expiration
}

/// @notice Reasons a VRF fulfillment may be safely ignored without reverting.
enum IgnoredFulfillmentReason {
    UnknownRequest,
    RoundNotPending,
    RandomnessAlreadyAccepted,
    InvalidWordCount,
    FulfillmentTimedOut
}

/// @notice Deployment-time values that governance cannot change.
struct ImmutableConfiguration {
    address activationToken;
    address rewardNFT;
    address weth;
    address vrfWrapper;
    address uniswapV4PoolManager;
    address canonicalHook;
    uint256 rewardNFTMaxSupply;
    uint256 vaultPrice;
    uint256 requiredBootstrapWeth;
    uint256 initialTokenPerWethWad;
    uint16 maxCombinedHookFeeBps;
    int24 canonicalTickSpacing;
    uint32 vrfCallbackGasLimit;
    uint16 vrfRequestConfirmations;
}

/// @notice Governed values snapshotted when a round is initialized.
struct RoundConfiguration {
    uint256 ticketPrice;
    uint256 ticketOperationsFee;
    uint256 playerRewardRate;
    uint256 ticketTarget;
    uint256 maxVrfCost;
    uint256 vrfTimeoutBlocks;
    uint256 requestCallerReward;
    uint256 finalizationCallerReward;
    uint16 winnerShareBps;
    uint16 nftShareBps;
    uint16 treasuryShareBps;
    uint16 buybackShareBps;
    uint192 operationsReserveCap;
}

/// @notice Governed activation economics applied to future tier transitions.
struct ActivationConfiguration {
    uint256[3] costs;
    uint256[3] destinationWeights;
    uint16 burnShareBps;
    uint16 nftShareBps;
    uint16 treasuryShareBps;
}

/// @notice Governed bilateral swap fee rates and same-asset routing shares.
struct HookConfiguration {
    uint16 inputFeeBps;
    uint16 outputFeeBps;
    uint16 polShareBps;
    uint16 nftShareBps;
    uint16 treasuryShareBps;
}

/// @notice Live governed execution parameters for permissionless pending buybacks.
struct BuybackConfiguration {
    uint16 slippageBps;
    uint16 callerTipBps;
    uint32 twapWindowSeconds;
    uint128 maximumWethChunk;
}

/// @notice One player's independent fee and ticket-reward permissions for a Builder.
struct BuilderApproval {
    uint16 maximumFeeBps;
    bool mayReceiveTicketRewards;
}

/// @notice Exact native payment and reward-routing preview for a builder-aware purchase.
struct BuilderTicketQuote {
    uint256 ticketValueEth;
    uint256 operationsFeeEth;
    uint256 builderFeeEth;
    uint256 totalEth;
    address rewardBeneficiary;
    bool rewardRedirectEffective;
}

/// @notice Complete one-time Diamond governance initialization payload.
struct GovernanceInitialization {
    ImmutableConfiguration immutableConfiguration;
    RoundConfiguration roundConfiguration;
    ActivationConfiguration activationConfiguration;
    HookConfiguration hookConfiguration;
    address treasuryReceiver;
    address guardian;
    BuybackConfiguration buybackConfiguration;
}

/// @notice Complete state and immutable economic snapshot for one round.
struct Round {
    RoundStatus status;
    RoundConfiguration config;
    uint256 ticketCount;
    uint256 winnerPoolWeth;
    uint256 totalPlayerRewardLiability;
    uint256 unclaimedPlayerRewardLiability;
    uint256 acceptedRandomWord;
    uint256 winningTicket;
    address winner;
    uint64 latestRequestBlock;
    uint32 requestAttempts;
    bool prizeClaimed;
    uint64 closedAtBlock;
}

/// @notice Deferred ticket-value routing and refundable balances for one round.
struct RoundSettlement {
    uint256 ticketEscrowWeth;
    uint256 winnerWeth;
    uint256 rewardNftWeth;
    uint256 bootstrapPolWeth;
    uint256 treasuryWeth;
    uint256 buybackWeth;
    uint256 provisionalNftIndexRay;
    uint256 provisionalNftRemainder;
    uint256 finalizedNftIndexRay;
    uint256 builderFeeEth;
    uint256 provisionalNftCrystallizedWeth;
}

/// @notice Lazy purchase-time Reward NFT eligibility carried across round resolution.
// forge-lint: disable-next-line(pascal-case-struct)
struct ProvisionalNFTRewardPosition {
    uint256 finalizedCheckpointRay;
    uint256 provisionalRoundId;
    uint256 provisionalCheckpointRay;
    uint256 provisionalClaimableWeth;
    uint256 claimableWeth;
}

/// @notice One purchase represented as the cumulative exclusive end and buyer.
struct TicketBatch {
    uint256 endExclusive;
    address buyer;
}

/// @notice Association between a Chainlink request and its frozen round.
struct RequestRecord {
    uint256 roundId;
    uint32 attempt;
    bool known;
}

/// @notice Global accounting for one Reward NFT asset-side index.
struct RewardBook {
    uint256 indexRay;
    uint256 indexRemainder;
    uint256 indexedAmount;
    uint256 crystallizedAmount;
    uint256 totalClaimable;
}

/// @notice Stored activation weight, checkpoints, and claims for one Reward NFT.
// forge-lint: disable-next-line(pascal-case-struct)
struct NFTRewardPosition {
    uint8 tier;
    uint256 storedWeight;
    uint256 wethCheckpointRay;
    uint256 tokenCheckpointRay;
    uint256 claimableWeth;
    uint256 claimableToken;
}

/// @notice Diamond-held liabilities and owned balances, separated by accounting class.
struct ProtocolAccountingView {
    uint256 winnerPoolWethLiability;
    uint256 rewardNftWethLiability;
    uint256 bootstrapPolWeth;
    uint256 operationsReserveEth;
    uint256 callerCreditsEth;
    uint256 playerTokenLiability;
    uint256 rewardNftTokenLiability;
    uint256 vaultBackingToken;
    uint256 ticketEscrowWeth;
    uint256 expiredTicketRefundWeth;
    uint256 pendingBuybackWeth;
    uint256 provisionalBuilderEth;
    uint256 expiredBuilderRefundEth;
}

/// @notice NFTVault supply, inventory, and TOKEN backing state.
struct VaultAccountingView {
    uint256 vaultPrice;
    uint256 maxSupply;
    uint256 mintedSupply;
    uint256 vaultInventory;
    uint256 circulatingNfts;
    uint256 vaultTokenBacking;
    uint256 requiredTokenBacking;
}

/// @notice Canonical pool and permanently locked liquidity state.
// forge-lint: disable-next-line(pascal-case-struct)
struct POLAccountingView {
    bool initialized;
    PoolId poolId;
    uint128 lockedLiquidity;
    uint256 pendingToken;
    uint256 pendingWeth;
}
