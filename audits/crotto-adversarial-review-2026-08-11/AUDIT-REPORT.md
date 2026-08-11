# Crotto Adversarial Smart-Contract Review

- **Review date:** 2026-08-11
- **Repository:** `EqualFiLabs/crotto`
- **Reviewed revision:** `bfbd26ca4cab8191eebbf4c5c2a2c8ac5543e77d`
- **Reviewed branch:** `master`
- **Review type:** adversarial source, accounting, integration, and lifecycle review
- **Status:** historical review with dispositions recorded on 2026-08-11

## Executive Summary

This review found two High-severity economic or winner-selection vulnerabilities,
five Medium-severity accounting, liveness, upgrade, and governance risks, and one
Low-severity integration defect.

The most important findings are:

1. Multiple outstanding VRF attempts let fulfillment ordering select among
   independently valid winners.
2. Automatic ticket buybacks derive all protection from the same manipulable
   current pool price, enabling sandwich extraction from ticket-funded WETH.
3. ActivationToken mint events are validated independently rather than against
   one global supply-capacity invariant, allowing finalized liabilities or the
   bootstrap mint to become permanently unexecutable.
4. The final-immutability transaction does not atomically prove a complete,
   canonical selector manifest before removing the upgrade path.

The repository's test suite is substantial and passed at the pinned revision.
The findings are primarily adversarial composition and extreme-state failures
that ordinary happy-path tests do not disprove.

**Release recommendation:** do not deploy Crotto to Ethereum Mainnet until H-01,
H-02, M-01, and M-02 are resolved or, for H-02, explicitly accepted with a
quantified economic-loss bound. M-03 and M-04 require a deliberate liveness
policy before progressive immutability is finalized.

## Finding Summary

| ID | Severity | Title | Disposition |
|---|---|---|---|
| H-01 | High | VRF fulfillment-order racing can select the lottery winner | Resolved on `master` |
| H-02 | High | Current-spot buyback protection permits sandwich extraction | Accepted economic risk |
| M-01 | Medium | Independent TOKEN mint checks can overcommit global supply capacity | Accepted privileged-configuration risk |
| M-02 | Medium | Final immutability can freeze an incomplete or altered selector set | Remediated in `6f2f00a` |
| M-03 | Medium | Mandatory buybacks can make valid ticket quantities unpurchasable | Resolved on `master` |
| M-04 | Medium | One immutable VRF dependency can permanently strand sold-out rounds | Resolved on `master` |
| M-05 | Medium | Timelock policy does not preserve the advertised delay guarantees | Accepted governance-operations risk |
| L-01 | Low | Declared integration views are absent from the deployed Diamond | Remediated in `26da639` |

## Remediation and Risk-Acceptance Record

This section records later decisions and code changes without rewriting the
point-in-time findings below. The detailed findings continue to describe
revision `bfbd26c`.

- **H-01 — resolved:** the lottery now permits one VRF request per sold-out
  round. There is no retry selector and therefore no callback-order choice
  among independently valid words.
- **H-02 — accepted:** current Crotto intentionally executes bounded pending
  buyback chunks through the canonical pool without TWAP or minimum-output
  protection. Public-ordering MEV and poor execution are accepted economic
  properties. The governed Maximum WETH Chunk bounds gross protocol exposure
  per execution; it does not guarantee price quality.
- **M-01 — accepted:** the timelock can configure an arithmetically
  representable but economically absurd Player Reward Rate that exhausts ERC-20
  supply capacity. The team accepts this privileged configuration risk rather
  than adding global lifetime-mint reservation machinery. Proposed operations
  remain cancellable before execution and configuration review is a deployment
  and governance requirement.
- **M-02 — remediated:** `6f2f00a` adds an owner/timelock-only atomic finalizer.
  Its calldata commits to the exact reviewed pre-final facet/address manifest;
  the same transaction removes `diamondCut`, ownership transfer, and the
  finalizer itself, then requires the exact compiled post-final selector count
  and selector-set hash. Stale routing, missing selectors, unexpected selectors,
  incomplete removal, or ownership changes revert the whole transaction.
- **M-03 — resolved:** ticket purchases escrow the Buyback allocation and do not
  call the PoolManager. Successful post-POL finalization moves it to pending
  Buyback WETH, and permissionless execution consumes bounded governed chunks.
  Buyback failure no longer blocks ticket sales or round finalization.
- **M-04 — resolved:** each sold-out round has a block deadline. If the sole VRF
  request is not fulfilled in time, anyone can expire the round, roll to the next
  round, and buyers can pull exact Ticket Price WETH and Builder surcharge ETH
  refunds. Operations Fees remain nonrefundable.
- **M-05 — accepted:** Crotto retains standard OpenZeppelin timelock delay
  updates and nonexpiring ready operations. Authorized proposers/cancellers are
  operationally responsible for canceling superseded operations. This is an
  explicit governance-process dependency rather than a claimed onchain expiry
  guarantee.
- **L-01 — remediated:** `26da639` implements the four missing configuration
  views through `LotteryViewFacet`, routes them through the deployment manifest,
  and adds Diamond-level return-value and selector coverage. The aggregate
  accounting view had already been implemented after the reviewed revision.

H-02, M-01, and M-05 remain open by design and must be carried into deployment
runbooks, monitoring, and any external security-review handoff. “Accepted” does
not mean technically eliminated.

## Scope

The review covered:

- all production Solidity under `src/`;
- Diamond storage namespaces, facet selectors, delegatecall context, and
  progressive immutability;
- Lottery ticket purchase, WETH routing, randomness, finalization, and claims;
- Operations Reserve, caller credits, Builder Fees, and native solvency;
- ActivationToken minting and burning;
- RewardNFT indexing, activation, transfer settlement, and claims;
- NFTVault issuance, inventory sale, redemption, and backing;
- canonical Uniswap v4 hook fees, callbacks, POL Pending, permanent liquidity,
  donations, compounding, and automatic ticket buybacks;
- governance, Guardian authority, timelock behavior, deployment scripts, and
  selector manifests;
- unit, fuzz, integration, and invariant tests relevant to these boundaries;
- current requirements, design, ADRs, and deployment configuration.

The review did not audit Chainlink, OpenZeppelin, Uniswap v4, WETH, Ethereum
consensus, frontends, indexers, multisig operations, or private transaction
infrastructure as independent products. Their Crotto-facing assumptions and
failure modes were reviewed.

No deployed Crotto Mainnet instance was supplied or reviewed. Mainnet dependency
runtime code hashes were checked against the addresses and expected hashes pinned
in `CrottoDeploymentConfig.sol`.

## Methodology

The review combined:

- entry-point, authority, custody, and liability mapping;
- complete general, access-control, proxy, governance, precision-math, ERC-20,
  ERC-721, AMM, oracle, assembly, and denial-of-service checklist passes;
- manual state-transition and checks-effects-interactions review;
- adversarial analysis of callback ordering, stale operations, extreme
  configurations, current-price manipulation, and irreversible finalization;
- selector and ERC-7201 storage review;
- review of existing fuzz and stateful invariants;
- focused reproduction with existing tests where the behavior was already
  encoded; and
- one complete repository test run at the pinned revision.

Severity reflects impact and practical preconditions:

- **High:** direct loss or redirection of material assets is possible through a
  realistic adversarial path.
- **Medium:** conditional asset loss, permanent liveness failure, or a material
  security-property failure requires a privileged action, dependency failure,
  extreme configuration, or narrower state.
- **Low:** correctness or integration failure with limited direct asset impact.

## Detailed Findings

## [H-01] VRF fulfillment-order racing can select the lottery winner

**Severity**: High

**Category**: Oracle / Chainlink VRF

**Location**: `src/diamond/facets/LotteryVRFFacet.sol:44-57,60-89`;
`src/diamond/facets/LotteryFinalizationFacet.sol:36-38`;
`test/lottery/LotteryRandomness.t.sol:213-220,317-329`

**Description**: Every successful retry creates another independently valid VRF
request for the same round, while all older request IDs remain eligible. The
first known request fulfilled while the round is `VRFPending` stores its word and
moves the round to `RandomReady`. Every later fulfillment is ignored.

The VRF proof prevents an arbitrary word from being forged, but it does not make
transaction ordering irrelevant. Once two valid results exist, the VRF
fulfillment operator can withhold or order its transactions, and a block builder
that observes both transactions can order them. That ordering chooses which word
is stored. Finalization directly calculates:

```text
winningTicket = acceptedRandomWord % ticketCount
```

The vendored Chainlink base contract explicitly warns that miners and the VRF
oracle influence response ordering and that concurrent requests must not allow
ordering to manipulate user-significant behavior.

**Proof of Concept**:

1. Alice owns ticket index `0`; Bob owns ticket index `1`.
2. Request A remains outstanding when a permissionless retry creates request B.
3. A's valid word is `2`, selecting Alice. B's valid word is `3`, selecting Bob.
4. Fulfill A first: A is accepted, the round becomes `RandomReady`, and B is
   ignored.
5. Fulfill B first instead: B is accepted and A is ignored.

The existing deterministic and fuzz tests prove the order dependence: they
assert that whichever request is fulfilled first permanently supplies the
accepted word. A targeted execution of
`test_FirstFulfillmentWinsAcrossOutstandingAttempts` passed and reproduced that
behavior.

This can redirect the complete Winner Pool after any retry. No compromised
contract key is required for a block builder that can observe two valid
fulfillment transactions, although practical exploitability depends on how the
VRF provider submits them.

**Recommendation**: Do not let arrival order choose among multiple randomness
samples for one prize. Prefer one canonical request per round. If a liveness
fallback is required, use a deterministic design that does not expose multiple
already-known candidate outputs to ordering or selective withholding.

Simply accepting the latest request is not sufficient without a carefully
defined cutoff: an eligible retry could front-run an observed older fulfillment
and reroll the outcome. Alternatives include a fixed, precommitted set of
requests whose results are combined under a deterministic threshold, or a
separate fallback beacon activated at a deterministic boundary. Add adversarial
tests proving winner independence across every valid callback ordering.

## [H-02] Current-spot buyback protection permits sandwich extraction

**Severity**: High

**Category**: AMM / Price manipulation / MEV

**Location**: `src/libraries/LibAutomaticBuyback.sol:84-94,164-185`;
`src/libraries/LibAutomaticBuybackMath.sol:44-52,71-96`;
`src/diamond/facets/LotteryTicketFacet.sol:134-145`;
`specs/onchain-lottery-nft-rewards/adr/0001-automatic-ticket-buybacks.md:158-181,351-360`

**Description**: An automatic buyback reads the canonical pool's instantaneous
`sqrtPriceX96`. It derives both `minimumNetTokenOut` and `sqrtPriceLimitX96` from
that same value. The limits constrain movement only after the read; they do not
constrain deviation from the price before an attacker transaction.

A searcher can front-run a visible ticket purchase with WETH-to-TOKEN, making
TOKEN more expensive. The ticket purchase then adopts the manipulated price as
its reference and executes its mandatory buyback. The buyback moves price
further in the same direction. The searcher back-runs with TOKEN-to-WETH and
captures part of the ticket-funded WETH.

The bilateral hook fees and growing POL increase attack cost but do not remove
the economic path. The configured 5% tolerance protects only against the
buyback's movement relative to the already-manipulated spot.

**Proof of Concept**:

1. Observe a post-POL ticket purchase and derive its exact 10% gross buyback
   budget from public round state and quantity.
2. Front-run with a canonical WETH-to-TOKEN swap.
3. The victim reads the manipulated `slot0` and calculates:

   ```text
   minimumNetTokenOut =
       manipulatedSpotNetTokenOut * (10_000 - slippageBps) / 10_000
   ```

4. The victim buyback executes within the limit measured from the manipulated
   price.
5. Back-run by selling the acquired TOKEN into the victim's added price impact.

As an illustrative constant-product calculation using the shipped 30 WETH /
300,000 TOKEN genesis ratio, a 0.5 WETH victim buyback, 50 BPS per fee leg, and an
8 WETH front-run produces approximately 0.043 WETH of attacker profit before gas
and before modeling incremental POL compounding. The exact value is state- and
implementation-dependent; the permissionless extraction path does not depend on
that one parameter set.

ADR 0001 already acknowledges that current-spot protection does not prevent
pre-execution manipulation. That makes this a known design risk, not a mitigated
one.

**Recommendation**: Anchor buyback execution to a price reference that predates
same-block manipulation. Use a canonical-pool TWAP or a bounded external
reference as a deviation check, and cap buyback size relative to active
liquidity. Protected transaction submission may supplement but must not replace
an onchain bound.

If current-spot execution is retained, explicitly accept this finding, run exact
Uniswap v4 sandwich simulations across bootstrap and steady-state liquidity,
and define the maximum tolerable extraction per ticket batch before launch.

## [M-01] Independent TOKEN mint checks can overcommit global supply capacity

**Severity**: Medium

**Category**: Precision math / Accounting

**Location**: `src/libraries/LibCrottoValidation.sol:55-68,71-84`;
`src/token/ActivationToken.sol:10-27,31-48`;
`src/diamond/facets/LotteryFinalizationFacet.sol:36-46,75-91`;
`src/diamond/facets/POLInitializationFacet.sol:29-48`

**Description**: Configuration validation independently proves that one round's
maximum player reward liability and the one-time bootstrap TOKEN amount each fit
in `uint256`. It does not reserve capacity against:

- the 10,000,000 TOKEN Genesis Treasury Mint;
- the still-pending bootstrap mint;
- already minted player rewards; or
- finalized but unclaimed player-reward liabilities.

OpenZeppelin's ERC-20 `_mint` performs checked addition to total supply. A
configuration can therefore pass validation, accept ticket value, finalize a
round, and establish liabilities that can never be minted. Likewise, immutable
bootstrap parameters can pass their independent calculation yet make
`initializePOL()` permanently revert after Bootstrap WETH has accumulated.

**Proof of Concept**:

Player reward path:

1. Configure `ticketTarget = 2` and
   `playerRewardRate = floor(type(uint256).max / 2)`.
2. The current validation passes because the round liability is
   `type(uint256).max - 1`.
3. Sell out and finalize the round. The liability is stored.
4. `claimPlayerRewards()` calls `mintPlayerReward()`. Adding any such claim to
   the existing 10,000,000 TOKEN genesis supply overflows, so every affected
   claim reverts atomically and remains outstanding.

Bootstrap path:

1. Choose representable immutable `requiredBootstrapWeth` and
   `initialTokenPerWethWad` whose product rounds to a bootstrap mint greater than
   `type(uint256).max - GENESIS_TREASURY_SUPPLY`.
2. Current immutable validation proves only that the standalone product fits.
3. After Bootstrap WETH reaches the threshold, the hook's one-time `_mint`
   overflows total supply. POL cannot initialize with those immutable values.

Future finalizations may also overflow the aggregate player liability counter
before any mint call occurs.

**Recommendation**: Define one explicit global TOKEN mint-capacity invariant.
Reserve capacity for genesis supply, the bootstrap mint until executed, all
finalized unclaimed liabilities, the maximum liability of the active round, and
already minted supply. Validate it at deployment, every round-configuration
update, finalization, and mint.

If Crotto intentionally has uncapped economic supply, arithmetic capacity still
needs a non-overcommittable bound. Add exact-boundary and multi-round tests rather
than testing each mint class in isolation.

## [M-02] Final immutability can freeze an incomplete or altered selector set

**Severity**: Medium

**Category**: EIP-2535 proxy / Governance

**Location**: `script/CrottoFinalImmutability.s.sol:24-86`;
`script/DeployCrotto.s.sol:152-160`

**Description**: The irreversible timelock payload only removes `diamondCut` and
`transferOwnership`. The manifest confirmation is an offchain script check
against an operator-supplied hash. The onchain payload does not assert that the
Diamond still has the expected facet manifest when it executes.

The post-execution check verifies only six retained selectors and omits critical
asset-exit paths such as:

- `claimWinnings`;
- `claimPlayerRewards`;
- `claimCallerRewards`;
- `claimNFTWethReward`;
- `claimNFTTokenReward`; and
- `redeemRewardNFT`.

It also runs after the broadcasted timelock transaction. A script failure cannot
revert an already-mined final cut.

Because execution is open, anyone can call the ready timelock operation directly
without the script. A different ready upgrade can alter or remove a claim facet
during the delay, after which the stale final-cut payload can permanently freeze
that altered state.

**Proof of Concept**:

1. Schedule the final cut.
2. Before it executes, execute another authorized cut that removes
   `claimWinnings` or routes it to a broken facet.
3. Call `TimelockController.execute` directly with the already-ready final-cut
   payload.
4. `diamondCut` and `transferOwnership` are removed without an onchain manifest
   assertion.
5. The missing claim selector cannot be restored, and Winner Pool WETH is
   permanently inaccessible through the protocol.

Even without a race, an operator can set
`EXPECTED_PRE_FINAL_MANIFEST_HASH` to the hash of an incomplete manifest; the
script has no canonical expected hash or complete selector list.

**Recommendation**: Make the final-cut transaction atomically validate a
canonical, release-pinned pre-final manifest and a complete set of required
post-final selectors. The validation must execute in the same transaction before
selector removal and revert the cut if any address or selector differs.

Include every round, claim, vault, builder, activation, reward, POL, hook,
governance, Guardian, and view selector required after immutability. Rehearse
negative cases for missing claim selectors, replaced facets, stale scheduled
cuts, and direct open-executor calls.

## [M-03] Mandatory buybacks can make valid ticket quantities unpurchasable

**Severity**: Medium

**Category**: AMM / Denial of service

**Location**: `src/diamond/facets/LotteryTicketFacet.sol:134-145`;
`src/libraries/LibAutomaticBuyback.sol:84-94,164-185`;
`src/libraries/LibCrottoValidation.sol:109-119`

**Description**: After POL initialization, every ticket purchase must execute the
entire aggregate buyback atomically. Any price-limit or minimum-output failure
reverts the complete purchase. Round validation proves only that the per-ticket
buyback input is nonzero and that the maximum integer fits the Uniswap signed
amount. It does not prove that one ticket, the advertised maximum quantity, or a
sellout remainder is executable against live or genesis liquidity.

With the shipped rehearsal economics, POL starts near 30 WETH / 300,000 TOKEN,
the ticket price is 1 ETH, the buyback share is 10%, and slippage is 5%. Bootstrap
reaches 30 WETH after 75 pre-POL tickets because the 30% NFT and 10% pre-POL
buyback shares both route to Bootstrap POL. A buyer can then validly request all
25 remaining tickets. The resulting 2.5 WETH buyback moves a simple full-range
reserve price by about 7.66%, exceeding the 5% bound and reverting the purchase.
Smaller purchases can complete, so the shipped configuration does not
necessarily freeze the round, but the canonical quantity API overstates what is
executable.

A governance-valid future snapshot or sufficiently adverse pool state can make
even one ticket's required buyback unexecutable. The active snapshot cannot be
changed; recovery then depends on a timelocked slippage change, external POL
donation, or an upgrade that may already have been removed.

**Proof of Concept**:

1. Initialize POL at the shipped 30 WETH threshold.
2. Leave 25 tickets in the current round.
3. Call `buyTickets(25)` with exact canonical payment.
4. The function accepts the quantity against `remainingTickets`, wraps and
   routes value, then the mandatory 2.5 WETH buyback reaches its price limit.
5. The whole purchase reverts.

The existing test
`test_SlippageFailureRollsBackPurchaseAndCanRetryAfterGovernanceUpdate` confirms
that buyback liveness gates ticket liveness and that recovery currently relies
on governance.

**Recommendation**: Add a live, direction-aware maximum executable quantity to
the quote and purchase path, and reject configurations that cannot execute one
ticket at initialized liquidity under the governed safety bound. Define a
terminal recovery policy before immutability for a round where one ticket is no
longer executable. Preserve atomic accounting; do not silently weaken the
current-price or settlement checks to make the purchase pass.

## [M-04] One immutable VRF dependency can permanently strand sold-out rounds

**Severity**: Medium

**Category**: Denial of service / External dependency

**Location**: `src/types/CrottoTypes.sol:30-46`;
`src/diamond/facets/LotteryVRFFacet.sol:33-89,92-130`;
`src/diamond/facets/LotteryFinalizationFacet.sol:29-50`;
`script/CrottoFinalImmutability.s.sol:24-33`

**Description**: Every round uses one deployment-pinned VRF wrapper. Requests and
retries call the same immutable wrapper, and only that wrapper may provide an
accepted fulfillment. There is no cancellation, participant refund, alternate
randomness source, or wrapper rotation path retained after final immutability.

If the wrapper stops accepting requests or stops fulfilling them, a sold-out
round remains `Closed` or `VRFPending`. `finalizeLottery()` requires
`RandomReady`, so the Winner Pool remains locked, player TOKEN entitlements are
not established, and the next round never opens.

The requirements acknowledge that normal operation depends on external
infrastructure availability. Acknowledgement does not provide a terminal fund
recovery path.

**Proof of Concept**:

1. Sell out a round so it becomes `Closed`.
2. Submit a request that the wrapper never fulfills, leaving the round
   `VRFPending`.
3. Wait for `vrfRetryDelay`; every retry still uses the same unavailable service.
4. `finalizeLottery()` always reverts with `RoundNotReadyForFinalization`.
5. After `diamondCut` is removed, no protocol path can change this lifecycle.

**Recommendation**: Define a manipulation-resistant terminal recovery mechanism
before final immutability. Options include a deployment-pinned secondary
verifiable-randomness provider activated only after a long outage, a constrained
timelocked wrapper migration preserving existing request provenance, or a
timeout-based round cancellation with exact participant refunds.

Do not let governance inject an arbitrary word or select the winner. The
recovery design must also avoid recreating H-01 by offering multiple selectable
random outputs.

## [M-05] Timelock policy does not preserve the advertised delay guarantees

**Severity**: Medium

**Category**: Governance

**Location**: `src/governance/CrottoTimelock.sol:7-23`;
`script/DeployCrotto.s.sol:152-160`;
`script/CrottoGovernanceOperations.s.sol:25-49`;
`lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:205-224,447-454`

**Description**: Crotto advertises delayed administrative changes and initializes
Mainnet with a seven-day delay, but the inherited `updateDelay(uint256)` accepts
zero. After one properly delayed self-call, every future configuration change,
treasury redirection, unpause, or Diamond cut can be scheduled and executed
without a user review window.

Separately, a scheduled OpenZeppelin operation never expires: any timestamp in
the past remains `Ready` until executed or canceled. Crotto payloads carry no
configuration version, deadline, or expected-current-state precondition. Because
the executor role is open to `address(0)`, any account can execute a forgotten
ready operation months later.

These behaviors are standard OpenZeppelin mechanics, but they do not preserve
the protocol-level expectation that administrative changes remain delayed and
current. A stale unpause can defeat a later Guardian pause; a stale Treasury
Receiver update can overwrite a newer destination and redirect future WETH and
TOKEN revenue.

**Proof of Concept**:

Delay removal:

1. Schedule `timelock.updateDelay(0)` and wait seven days.
2. Execute it through the timelock.
3. Schedule and execute a Diamond cut or Treasury Receiver update in the same
   block with `delay = 0`.

Stale operation:

1. Schedule a valid `setTreasuryReceiver(oldReceiver)` or unpause operation.
2. Let it become ready but do not execute or cancel it.
3. Later establish a new receiver or Guardian pause.
4. Any account executes the old ready operation, restoring obsolete state.

**Recommendation**: Override delay updates with an immutable production floor.
If emergency governance requires a shorter delay, define that authority and its
bounded surface explicitly rather than reducing the global timelock.

Add operation expiry or require governance payloads to include an expected
configuration version and deadline. Operational monitoring and cancellation are
useful defense in depth but should not be the only stale-operation control.

## [L-01] Declared integration views are absent from the deployed Diamond

**Severity**: Low

**Category**: Interface / Deployment integration

**Location**: `src/interfaces/ICrottoView.sol:18-27,65`;
`src/diamond/facets/LotteryViewFacet.sol:8-69`;
`script/DeployCrotto.s.sol:54-69`;
`script/CrottoGovernanceOperations.s.sol:66-74`

**Description**: `ICrottoView` declares five integration methods that no
production facet implements:

- `immutableConfiguration()`;
- `currentRoundConfiguration()`;
- `currentActivationConfiguration()`;
- `currentHookConfiguration()`; and
- `protocolAccounting()`.

The deployment installs `LotteryViewFacet`, but that facet exposes only round,
ticket, reward-ticket, and request views. Selector enumeration across all
production facets found no implementation for the five declared selectors.

`ExecuteRoundConfiguration` calls the absent
`currentRoundConfiguration()` after broadcasting the governance transaction.
The governance transaction can succeed, then the script fails during its local
verification. Frontends and monitoring implemented against `ICrottoView` also
revert with the Diamond's missing-selector error.

This does not directly debit a user, but it weakens configuration and liability
observability at exactly the integration boundary relied upon for safe operation.

**Proof of Concept**:

1. Deploy using `DeployCrotto.s.sol`.
2. Call any of the five selectors through the Diamond.
3. No installed facet owns the selector, so the fallback reverts.
4. Execute a round-configuration operation through the provided script; the
   onchain setter executes, then post-broadcast verification calls the missing
   selector and fails.

**Recommendation**: Implement the declared configuration and aggregate-accounting
views in a bounded facet, include their selectors in deployment and final
immutability manifests, and add Diamond-routed selector and return-value tests.
If the interface is not intended to be supported, remove the declarations and
replace the governance verification path before release.

## Positive Security Properties Observed

The review did not identify a confirmed exploit in the following areas:

- native Operations Reserve, caller-credit, and Builder Fee liability separation;
- Builder approval ceilings, voluntary surcharge separation, and pull claims;
- exact ERC-20 transfer-delta enforcement for CROTTO and WETH;
- RewardNFT ownership authorization, transfer settlement, tier reset, and
  attached token-ID claims;
- NFTVault fixed-price backing under purchase and redemption;
- hook and PoolManager callback authentication;
- bilateral fee conservation and no-active-NFT fallthrough to POL;
- POL Pending per-currency solvency and additive locked-liquidity accounting;
- absence of a canonical liquidity-removal path;
- cross-facet reentrancy protection on reviewed value-moving paths;
- namespaced Diamond storage uniqueness and selector collision handling;
- Guardian inability to pause swaps, seize funds, change configuration, or
  unpause; and
- bounded participant-independent work in normal production functions.

These observations are not a guarantee that undiscovered vulnerabilities do not
exist.

## Validation Evidence

At revision `bfbd26ca4cab8191eebbf4c5c2a2c8ac5543e77d`:

```text
forge fmt --check
forge build
forge test -vv
```

Result:

```text
47 suites
363 tests passed
0 failed
0 skipped
```

The full run included the repository's unit, fuzz, integration, Diamond-cut,
accounting-invariant, and protocol-stateful suites under the configured 1,000
fuzz runs and 256 invariant runs with depth 50.

Focused reproduction:

```text
forge test --match-path test/lottery/LotteryRandomness.t.sol \
  --match-test test_FirstFulfillmentWinsAcrossOutstandingAttempts -vv
```

Result: `1 passed; 0 failed; 0 skipped`.

The configured Ethereum Mainnet addresses for WETH, Uniswap v4 PoolManager,
Chainlink VRF v2.5 wrapper, and the deterministic CREATE2 deployer all had live
runtime code hashes matching `CrottoDeploymentConfig.sol` on 2026-08-11. This
checks deployment provenance only; it is not an audit of those dependencies.

The project compiles with Solidity 0.8.33, optimizer enabled, `via_ir = true`, and
Cancun EVM output. The official
[Solidity 0.8.33 known-bugs list](https://docs.soliditylang.org/en/v0.8.33/bugs.html)
was reviewed; no listed condition was found to apply to the reviewed source.

Aderyn 0.1.9 was attempted but could not parse the project's `osaka` Foundry
configuration emitted during config extraction. It terminated with
`Unknown evm version: osaka`; no Aderyn result is claimed.

At the remediation branch head, the primary agent performed one bounded
security-focused delta review and added the missing real timelock
schedule/permissionless-execute regression. Final validation used:

```text
forge fmt --check
forge build
FOUNDRY_PROFILE=stateful forge test -vv
git diff --check master...HEAD
```

Formatting and compilation succeeded, and the complete configured unit, fuzz,
integration, Diamond-cut, accounting-invariant, and unified protocol-stateful
suites passed with no test failure or skip. Foundry emitted existing lint notes
and the vendored canonical WETH deprecation warning; none was a compilation or
test failure. No target-chain fork proof was run in this remediation slice.

## Trust Assumptions and Residual Risks

Even after remediating the findings, Crotto intentionally retains material trust
and economic assumptions:

- Until the final Diamond cut, the timelock can replace arbitrary facets after
  its effective delay.
- The external Treasury Receiver has unrestricted custody and spending authority
  over value delivered to it.
- Chainlink VRF availability and honest fulfillment remain necessary for a
  successful round; deadline expiration and exact buyer refunds provide the
  terminal unavailable-provider path.
- The canonical Uniswap v4 PoolManager, WETH, and hook remain external execution
  and availability boundaries.
- Permanent POL is intentionally irreversible; donation and compounding errors
  have no withdrawal recovery path.
- Buyback execution intentionally exposes bounded chunks to public-ordering MEV
  under the accepted H-02 disposition.
- Governance operations can remain ready indefinitely and the timelock delay can
  be changed through a delayed self-call; proposers/cancellers must cancel
  superseded operations under the accepted M-05 disposition.
- Governance review must reject economically absurd Player Reward Rates that
  approach ERC-20 arithmetic capacity under the accepted M-01 disposition.
- Forced token or ETH transfers can create surplus but do not create a withdrawal
  entitlement.
- Progressive immutability converts every retained selector and dependency into
  a permanent release decision.

## Limitations

This is a point-in-time review of the pinned source revision, not a guarantee of
security. No production Crotto deployment was available for state inspection.
The sandwich calculation is an illustrative reserve model, not a complete
Mainnet-builder or Uniswap v4 fork exploit. External dependencies were checked at
their Crotto integration boundaries but not independently audited. Multisig
signer security, private order flow, frontend correctness, indexer correctness,
and operational key management were outside scope.

Any remediation that changes randomness, buyback pricing, TOKEN capacity,
timelock policy, or final immutability creates a material security boundary and
should receive focused adversarial regression coverage followed by one complete
final validation gate.
