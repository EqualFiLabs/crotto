# Crotto

Crotto is an onchain lottery and economic primitive. Lottery participation emits the Activation Token, fixed-supply
Reward NFTs can be activated for revenue participation, and a canonical Uniswap v4 TOKEN/WETH pool grows permanently
locked protocol-owned liquidity.

This repository currently contains the protocol foundation: pinned dependencies, shared types and validation rules,
and the public interfaces that future implementation facets and satellite contracts must satisfy. It does not yet
contain deployable lottery, token, NFT, vault, or hook behavior.

## Architecture

- An EIP-2535 Diamond will own lottery, governance, reward accounting, vault, and POL initialization state.
- `ActivationToken`, `RewardNFT`, and `CrottoSwapFeeHook` will be narrow satellite contracts controlled by the Diamond.
- User-facing economic flows use WETH. Ticket purchases accept native ETH only to wrap it immediately; caller
  reimbursements and tips remain native ETH because Chainlink VRF is paid natively.
- NFTVault redemption backing, lottery liabilities, RewardNFT rewards, treasury balances, and POL are isolated
  accounting classes.
- The canonical Uniswap v4 pool is protocol-owned only. Third parties remain free to create unrelated external pools.

## Toolchain

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then initialize the exact dependency graph:

```bash
git submodule update --init --recursive
forge build
forge test
```

The project pins Solidity `0.8.33`, the Cancun EVM target, optimizer runs at 200, and IR compilation. Dependency refs
are recorded in `foundry.lock` and as Git submodule commits:

- forge-std `v1.16.2`
- OpenZeppelin Contracts `v5.6.1`
- Chainlink EVM Contracts `v1.5.0`
- Uniswap v4-periphery commit `3779387e5d296f39df543d23524b050f89a62917`
- Uniswap v4-core commit `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`, nested under v4-periphery

## License

Crotto is licensed under the Business Source License 1.1. See [LICENSE](LICENSE) for the use terms and scheduled
change to GPL-2.0-or-later.
