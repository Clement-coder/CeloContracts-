# CeloContracts

A collection of production-grade Solidity smart contracts deployed on the Celo blockchain.

## Contracts

| Contract | Description |
|---|---|
| `Saving_contract` | CELO savings with lock durations and partial withdrawals |
| `loan_contract` | Collateralized CELO loans with interest |
| `task_contract` | On-chain task platform with bounties |
| `crowdfunding` | Crowdfunding campaigns with refund support |
| `Staking` | ERC20 staking with reward distribution |
| `Vesting` | Token vesting with cliff and linear release |
| `Multisig` | Multi-signature wallet |
| `Escrow` | Two-party escrow with arbitration |
| `Lottery` | Provably fair on-chain lottery |
| `DAO_Governance` | On-chain DAO with proposals and voting |
| `Dutch_Auction` | Descending-price Dutch auction |
| `NFT_marketplace` | ERC721 NFT marketplace |
| `Flash` | Flash loan provider |
| `Subscription` | Recurring subscription payments |
| `Token_Swap` | Constant-product AMM (CELO ↔ ERC20) |
| `ERC20_Token` | ERC20 token with mint/burn and supply cap |
| `ERC721_NFT` | ERC721 NFT with per-token URI and supply cap |

## Stack

- [Foundry](https://book.getfoundry.sh/) — build, test, deploy
- Solidity `0.8.20`
- Celo Mainnet (`chainId: 42220`)

## Usage

```shell
forge build
forge test
forge script script/<Name>.s.sol --rpc-url celo --broadcast
```
