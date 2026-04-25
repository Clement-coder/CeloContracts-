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

## MerkleAirdrop

Distributes ERC20 tokens to a pre-committed list of recipients using Merkle proofs.

### Contracts
- `AirdropToken` — minimal ERC20 reward token (ADT, 18 decimals)
- `MerkleAirdrop` — claim contract; each `(address, amount)` leaf is double-hashed

### Leaf encoding
```
leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
```

### Usage
1. Build your Merkle tree off-chain
2. Deploy `AirdropToken` + `MerkleAirdrop` with the root
3. Fund `MerkleAirdrop` with the token supply
4. Recipients call `claim(amount, proof)`
5. Owner calls `sweep(treasury)` to recover unclaimed tokens

### Deploy
```shell
forge script script/MerkleAirdrop.s.sol --rpc-url celo --broadcast
```

### Test
```shell
forge test -vvv
```

![Solidity](https://img.shields.io/badge/solidity-0.8.20-blue)

## License
MIT
