# Liquid Protocol — Architecture Overview

> TODO: Document the Liquid Protocol system architecture.

## Topics to Cover

- Factory contract (`Liquid.sol`) and deployment flow
- Modular plugin system: hooks, LP lockers, extensions, MEV modules
- Allowlist and access control model (`OwnerAdmins`)
- Token deployment lifecycle (CREATE2, pool init, liquidity, extensions, MEV)
- Cross-chain support via IERC7802 (Superchain)
