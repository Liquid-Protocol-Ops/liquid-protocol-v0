# Security Policy

## Scope

This repository contains the smart contracts for **Liquid Protocol** deployed on Base mainnet. Security of these contracts is critical — they handle token deployment, LP locking, fee collection, and MEV protection.

## Reporting a Vulnerability

If you believe you have found a security issue, **please report it privately to slaterg@mog.capital or mikeongay@mog.capital**.

### Contact

Email us at `slaterg@mog.capital` and include:
- A clear description of the issue.
- The assessed severity (e.g., low/medium/high/critical).
- Affected contract(s) and function(s).
- A proof of concept or minimum reproducible example.

We will acknowledge receipt within 48 hours and work with you on a coordinated fix.

### Audit History

The following audits were conducted on the **upstream Clanker v4 contracts** ([clanker-devco/v4-contracts](https://github.com/clanker-devco/v4-contracts)), which Liquid Protocol uses as the basis for its fork. The core hook, locker, and extension logic is architecturally identical to the audited codebase.

- Cantina V4 Audit (see `audits/cantina_v4_audit_1.pdf`)
- Macro V4 Audit Round 1 (see `audits/macro_v4_audit_1.pdf`)
- Macro V4 Audit Round 2 (see `audits/macro_v4_audit_2.pdf`)

### Do NOT

- Open a public GitHub issue for security vulnerabilities.
- Exploit a vulnerability on mainnet.
- Disclose details publicly before a fix is deployed.
