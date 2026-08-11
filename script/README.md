# Crotto Ethereum deployment

These scripts target Ethereum Sepolia (`11155111`) for rehearsal and Ethereum
Mainnet (`1`) for launch. They reject every other chain and verify the runtime
code hashes of WETH, Uniswap v4 PoolManager, Chainlink VRF v2.5 Wrapper, and the
universal CREATE2 deployer before creating any protocol contract.

`config/sepolia-rehearsal.json` is an executable rehearsal fixture, not a launch
recommendation. Mainnet deployment requires an explicitly supplied, reviewed
configuration file with production treasury, guardian, proposer, and economic
values, including a round-snapshotted Operations Reserve Cap. Configuration
files contain public inputs only.

## Deployment rehearsal

Use Forge account or hardware-wallet options for signing. Never put a private
key in a configuration file or committed environment file.

```bash
export DEPLOYER=0xYourDeploymentAccount
export CROTTO_DEPLOYMENT_CONFIG=script/config/sepolia-rehearsal.json
forge script script/DeployCrotto.s.sol:DeployCrotto --rpc-url "$ETH_SEPOLIA"
```

The command above simulates and does not broadcast. A successful rehearsal
deploys the complete graph in the forked EVM, checks all immutable bindings and
initial economics, verifies the compiled selector manifest, transfers Diamond
ownership to the timelock, and proves that the deployment account no longer has
the timelock bootstrap-admin role.

The script resolves the Diamond/TOKEN/hook constructor dependency by deploying
a Diamond shell, predicting the next TOKEN CREATE address, mining the hook salt
for the universal CREATE2 deployer, then atomically installing and initializing
the application facets. ActivationToken still mints exactly 10,000,000 CROTTO
to the configured external treasury, and no post-launch general mint authority
is introduced.

## Typed timelock operations

`CrottoGovernanceOperations.s.sol` contains separate schedule and execute entry
contracts for only these supported updates:

- round configuration;
- automatic-buyback chunk and caller-tip settings;
- external treasury receiver; and
- canonical-hook fees and allocations.

Each operation reads the same reviewed configuration file, requires the Diamond
to be owned by the configured timelock, uses a caller-supplied operation salt,
and verifies timelock state after scheduling or execution. There is no generic
arbitrary-call script and no governance helper for treasury spending, ticket
buybacks, or permissionless POL donations.

Example:

```bash
export CROTTO_DIAMOND=0xDeployedDiamond
export CROTTO_TIMELOCK=0xDeployedTimelock
export CROTTO_DEPLOYMENT_CONFIG=script/config/reviewed-config.json
export PROPOSER=0xAuthorizedProposer
export EXECUTOR=0xExecutionAccount
export OPERATION_SALT=0xUniqueBytes32Salt

forge script script/CrottoGovernanceOperations.s.sol:ScheduleRoundConfiguration --rpc-url "$RPC_URL" --broadcast
forge script script/CrottoGovernanceOperations.s.sol:ExecuteRoundConfiguration --rpc-url "$RPC_URL" --broadcast
```

Reviewed configuration files must remain under `script/config`, which is the
directory granted read access by `foundry.toml`.

## Progressive immutability

`CrottoFinalImmutability.s.sol` schedules and executes the irreversible removal
of `diamondCut` and `transferOwnership`. Both phases require:

- `CONFIRM_FINAL_IMMUTABILITY=true`; and
- `EXPECTED_PRE_FINAL_MANIFEST_HASH` equal to the live, reviewed selector
  manifest hash.

Execution verifies that both mutation selectors are absent, Diamond ownership
remains the timelock, essential governance and user selectors remain routed,
and selector reinstallation fails. Do not schedule this operation until the
release candidate and exact live manifest have completed the designated
security review.
