// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.33;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Lifecycle states for a sellout-driven Crotto round.
enum RoundStatus {
    Open,
    Closed,
    VRFPending,
    RandomReady,
    Finalized
}

/// @notice Permissionless lifecycle actions that earn native ETH caller credits.
enum CallerAction {
    RandomnessRequest,
    RandomnessRetry,
    Finalization
}

/// @notice Reasons a VRF fulfillment may be safely ignored without reverting.
enum IgnoredFulfillmentReason {
    UnknownRequest,
    RoundNotPending,
    RandomnessAlreadyAccepted,
    InvalidWordCount
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
}

/// @notice Governed values snapshotted when a round is initialized.
struct RoundConfiguration {
    uint256 ticketPrice;
    uint256 ticketOperationsFee;
    uint256 playerRewardRate;
    uint256 ticketTarget;
    uint256 maxVrfCost;
    uint256 vrfRetryDelay;
    uint256 requestCallerReward;
    uint256 finalizationCallerReward;
    uint16 winnerShareBps;
    uint16 nftShareBps;
    uint16 treasuryShareBps;
    uint16 buybackShareBps;
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

/// @notice Complete one-time Diamond governance initialization payload.
struct GovernanceInitialization {
    ImmutableConfiguration immutableConfiguration;
    RoundConfiguration roundConfiguration;
    ActivationConfiguration activationConfiguration;
    HookConfiguration hookConfiguration;
    address treasuryReceiver;
    address guardian;
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
    uint64 latestRequestAt;
    uint32 requestAttempts;
    bool prizeClaimed;
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
