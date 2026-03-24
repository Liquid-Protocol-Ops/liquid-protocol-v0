# Stale Deployments

These Foundry broadcast files are from intermediate or superseded deployment runs during the initial mainnet launch.

## Intermediate Runs (pre-final attempts)

These runs were executed before the final deployment configuration was settled. They deployed to the correct chain (Base, 8453) but were superseded by later runs.

| Script | Archived Runs |
|--------|--------------|
| `00_DeployCore.s.sol` | `run-1773432546214`, `run-1773434276547` |
| `01_DeployHooks.s.sol` | `run-1773432807176`, `run-1773434481675` |
| `02_DeployExtensions.s.sol` | `run-1773433042430`, `run-1773433257792`, `run-1773434577962` |

## Superseded Script

`03_DeployLpLockerAndMev.s.sol` — deployed `LiquidLpLockerFeeConversion` at `0x9529fb583793ac8955130c2e1854963f8c686221`, which is **not** the canonical deployed address. This script was replaced by the split scripts `03a_DeployMev.s.sol` + `03b_DeployLpLocker.s.sol`, which produced the final canonical deployment at `0x77247fCD1d5e34A3703AcA898A591Dc7422435f3`.
