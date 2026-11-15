# Yearn V3 Tranche Strategy

Risk tranches over a single Yearn V3 vault. Every tranche is a tokenized strategy that deposits into the same vault. Junior tranches take losses first and are paid a premium for it.

- **Cover:** at `report()`, a tranche whose holdings are below its `totalAssets` is topped up by the tranches below it, most junior first.
- **Premium:** at `report()`, a tranche passes `premium` of its profit down to its junior.
- **Cooldown:** tranches below the most senior can have a withdrawal cooldown of up to 90 days, followed by a 7-day window. The most senior never has one.
- **Losses:** a tranche only reports a loss once management turns its health check off.
- **Factory:** `StrategyFactory.newStrategy` deploys a tranche below a given senior, which management then links with `setJunior`.

## Usage

```sh
cp .env.example .env # set ETH_RPC_URL to an archive node
make build
make test
```

`script/Deploy.s.sol` deploys the factory and three linked tranches on yvUSD.
