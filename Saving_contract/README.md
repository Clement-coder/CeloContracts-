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
forge script script/Savings.s.sol --rpc-url celo --broadcast
```

![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)

## Contract
`Saving_contract`

![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)

## License

MIT

## TimelockController

Governance timelock for the Savings contract. Admin actions (pause, unpause, transferOwnership) must be queued, wait for the configured delay, then executed within the grace period.

### Constants
- `MIN_DELAY`: 1 day
- `MAX_DELAY`: 30 days
- `GRACE_PERIOD`: 14 days

### Roles
- **Admin**: update delay, manage roles
- **Proposer**: queue and cancel transactions
- **Executor**: execute queued transactions after delay

### Deploy
```shell
forge script script/TimelockController.s.sol --rpc-url celo --broadcast
```
