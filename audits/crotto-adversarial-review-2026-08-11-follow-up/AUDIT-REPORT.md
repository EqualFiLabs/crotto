# Crotto Follow-up Adversarial Security Review

- **Reviewed revision:** `92a66aba132520b624016e9a0a8f237d83a68f6d`
- **Remediation revision:** `7712d5c` on `fix/governed-pol-additions`
- **Branch:** `fix/audit-remediation` (open PR #32 at review time)
- **Base reference:** `origin/master` at `695859a8c9b24ed959cd422f375c3703adbb0a64`
- **Review date:** 2026-08-11
- **Review type:** internal adversarial source review with focused exploit validation

## Executive Summary

This follow-up found **one new High-severity issue**. The permissionless
`donatePOL` path and native Uniswap v4 donations let an attacker inject a chosen
matching asset while the hook held large one-sided POL Pending. The attacker
could move the canonical spot price, trigger compounding at that ratio, and
reverse the movement for a net gain. A focused Foundry proof extracted
approximately **2.4963 WETH of marked profit** from a scenario with 100 WETH of
one-sided POL Pending.

This is distinct from historical H-02. H-02 concerns the intentionally
unprotected execution price of ticket-funded TOKEN buybacks. The new finding
concerns the price at which the hook converts already-owned POL Pending assets
into permanent liquidity, and it permits extraction even when no buyback is
being executed.

No new Critical, Medium, or Low issue was confirmed in the lottery settlement,
refund, Builder, Operations, Reward NFT, NFTVault, token, Diamond, governance,
VRF, or final-immutability surfaces reviewed.

H-03 was remediated by removing permissionless hook donations, rejecting every
native v4 donation in `beforeDonate`, and permitting new externally funded POL
only through an exact timelock-governed call naming the consenting funder.
Automatic after-swap compounding and the permissionless backup compounder remain
unchanged. The original permissionless matching-asset injection required by the
proof is no longer reachable.

## Findings Summary

| ID | Severity | Title | Status |
|---|---:|---|---|
| H-03 | High | Attacker-controlled matching assets expose one-sided pending value | Resolved |

The numbering continues the historical review's High-severity findings.

## [H-03] Attacker-controlled matching assets expose one-sided pending value

**Severity**: High

**Category**: evm-audit-defi-amm

**Original location**: `CrottoSwapFeeHook.donatePOL()`, native
`PoolManager.donate()`, and `CrottoSwapFeeHook._compoundUnlocked()`

**Description**: The original `donatePOL()` immediately entered
`_compoundUnlocked()`. Native `PoolManager.donate()` could also create position
fees that the hook collected into POL Pending before compounding. Both paths let
an arbitrary attacker supply a chosen missing asset. `_compoundUnlocked()` reads
the canonical pool's current `slot0` to determine how much full-range liquidity
the matched pending inventory supports.

An attacker can therefore move the spot price before causing compounding. If
the hook has accumulated a large one-sided pending balance, the attacker
supplies the opposite asset at the manipulated price. The hook then commits
protocol inventory into the permanent position at an unfavorable ratio. The
attacker reverses the original trade against the newly deepened pool and
captures part of the protocol inventory. Locked liquidity remains monotonic,
but monotonic liquidity units do not guarantee monotonic economic value.

One-sided inventory is a normal reachable state. `creditPOLWeth()` deliberately
records WETH without compounding, bootstrap excess can remain unmatched, and fee
flow can leave an unmatched side. The exploitable step was permissionless
injection of the opposite asset at an attacker-selected moment.

**Proof of Concept**: A focused Forge probe used the real v4 PoolManager,
canonical hook, and swap router with these starting conditions:

1. Initialize the canonical position with 30 WETH and 300,000 CROTTO, a starting
   price of 10,000 CROTTO per WETH.
2. Place 100 WETH into one-sided WETH POL Pending.
3. Exact-input swap 40 WETH for CROTTO to move the canonical spot price.
4. Donate half of the acquired CROTTO amount. `donatePOL()` immediately calls
   `_compoundThroughUnlock()`, and `_compoundUnlocked()` pairs protocol WETH at
   the manipulated `slot0`.
5. Sell an amount equal to the originally acquired CROTTO back into the pool.
   Supplying the donated half from pre-existing external inventory makes the
   attacker's net TOKEN cost explicit.

The measured result, inclusive of the hook's bilateral fees, was:

```text
gross WETH balance increase: 11.006591051338649691 WETH
net external TOKEN spent:    85,102.435530085959885252 CROTTO
TOKEN marked at start price:  8.510243553008595988 WETH
marked attacker profit:       2.496347498330053703 WETH
```

The probe was used only to validate the attack and was removed from the working
test suite after the evidence was recorded. The exact optimum depends on pool
depth, pending imbalance, fees, and available attack capital, but positive
profit establishes the loss path.

**Remediation**: The hook now enables `beforeDonate` and unconditionally rejects
native one-sided and two-sided v4 donations. The permissionless `donatePOL`
surface was replaced with Diamond-only `addPOL(funder, tokenAmount, wethAmount)`.
`GovernanceFacet.addPOL` is owner-only, so deployed additions require the
timelock to commit to a named non-protocol external funder and exact amounts.
The hook pulls those assets directly from the pre-approving funder with exact
debit and receipt checks, credits POL Pending, and compounds atomically.
The Diamond, its satellites and facets, the current owner/timelock, and other
protocol custody addresses are rejected as funders; the Guardian receives no
addition authority.

Automatic after-swap compounding and permissionless `compoundPOL()` remain
available because neither lets a caller inject a chosen asset. Current-spot
execution for the rare governed addition is an explicit trusted-governance
boundary: the timelock controls the scheduled amounts, and the named funder can
withhold or revoke allowance before execution. Tests cover hook-only-Diamond
authorization, timelock authorization, protocol-funder rejection, exact pulls,
one- and two-sided v4 donation rejection, pending solvency, unmatched inventory,
and monotonic locked liquidity.

## Historical Accepted Risks

The following issues from the earlier report remain accepted design or
governance risks. They were verified as still present but are not counted as new
findings:

- **H-02:** ticket-funded buybacks use the current market with an extreme
  direction-aware price limit and no minimum output. This is an explicit
  economic choice, although it remains MEV-extractable.
- **M-01:** privileged configuration can select an arithmetically representable
  player reward rate that eventually exhausts ERC-20 supply capacity.
- **M-05:** ready timelock operations do not expire and the timelock can change
  its future minimum delay through a delayed self-call.

H-03 should not be folded into the H-02 acceptance. Removing buyback slippage
protection does not imply consent for third parties to extract assets already
owned by permanent POL during liquidity addition.

## Review Coverage

The review covered:

- ticket purchase, WETH wrapping, round escrow, successful settlement,
  expiration, refunds, winner claims, TOKEN rewards, and round rollover;
- Builder approvals, voluntary fees, reward redirection, provisional and
  matured credits, refunds, claims, and native solvency;
- Operations Reserve funding, cap behavior, VRF spending, caller credits, and
  native transfers;
- Reward NFT activation, transfers, provisional and matured reward indices,
  claims, NFTVault issuance/redemption, and TOKEN backing;
- ActivationToken and RewardNFT mint/burn authorities;
- canonical v4 pool initialization, bilateral hook fees, callback
  authentication, pending POL, donations, fee collection, compounding,
  permanent-liquidity restrictions, and deferred buybacks;
- VRF request, fulfillment, timeout, expiration, and winner selection;
- EIP-2535 selector routing, ERC-7201 storage, initialization, ownership,
  timelock and Guardian authority, deployment sequencing, and atomic final
  immutability; and
- cross-facet reentrancy, exact transfer deltas, forced balances, casts,
  rounding, overflow, callback ordering, and liability conservation.

Raw specialist working notes were intentionally excluded from the public
repository. This report contains the confirmed finding, exploit evidence,
disposition, and remediation boundary.

## Validation Evidence

Focused evidence used during this review:

```text
forge test --match-path test/governance/FinalImmutability.t.sol -vv
Result: 6 passed; 0 failed; 0 skipped

forge test --match-path test/liquidity/CrottoSwapFeeHook.t.sol
Result: 22 passed; 0 failed; 0 skipped

forge test --match-path test/governance/DiamondGovernance.t.sol
Result: 25 passed; 0 failed; 0 skipped

forge test --match-path test/invariant/POLAccountingInvariant.t.sol
Result: 3 passed; 0 failed; 0 skipped; 256 runs and 12,800 calls per invariant

FOUNDRY_PROFILE=stateful forge test --match-path test/invariant/CrottoProtocolInvariant.t.sol
Result: 5 passed; 0 failed; 0 skipped; 256 runs and 12,800 calls per invariant

Focused temporary v4 exploit probe
Result: positive marked profit of 2.496347498330053703 WETH

forge fmt --check && forge build -q && forge test -q && FOUNDRY_PROFILE=stateful forge test -q
Result: passed at remediation revision 7712d5c
```

The release-candidate revision had already passed the repository's complete
applicable unit/fuzz/stateful validation gate before this follow-up began. This
audit intentionally did not make each specialist rerun that same suite. Aderyn
was also run once against `src` with 63 detectors; its high-severity alerts were
manually triaged as generic Diamond/initializer/transfer false positives or
expected architecture and produced no additional confirmed finding.

## Limitations

This is an internal adversarial review, not independent third-party assurance.
It reviewed the pinned source revision and local Foundry execution. It did not
verify a live deployment, proposer Safe policy, production RPC behavior,
Chainlink service operation, or real mempool execution. Economic profitability
will vary with liquidity, price, fee configuration, and available capital; the
focused proof establishes possibility, not a maximum loss bound.
