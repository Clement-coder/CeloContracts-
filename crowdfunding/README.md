## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## Build
```shell
forge build
```

## Test
```shell
forge test -vvv
```

## Deploy
```shell
forge script script/Crowdfunding.s.sol --rpc-url celo --broadcast
```

## Contract
`crowdfunding`

![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)

## Bug Fixes Applied

1. **Wrong error in setReferralRate** — was reverting with `GoalTooLow` instead of `ReferralRateTooHigh`
2. **extendCampaign deadline cap broken** — was computing `originalStart = deadline - MAX_DURATION` (wrong for short campaigns); fixed by storing `start` in Campaign struct
3. **extendCampaign missing deadline check** — could extend a campaign after it expired; added `block.timestamp >= c.deadline` guard
4. **Missing interface entries** — `contributeWithReferral`, `withdrawReferralRewards`, `extendCampaign`, `setReferralRate`, `ReferralRateTooHigh` were absent from ICrowdfunding
5. **Stale comments removed** — 50 "Improvement" stub comments and stale commit markers cleaned up

## Test Coverage

- 120+ unit, fuzz, and integration tests
- All edge cases covered: boundary values, reentrancy, access control, state transitions
