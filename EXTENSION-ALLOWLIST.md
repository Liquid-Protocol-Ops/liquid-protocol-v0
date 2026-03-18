# Extension Allowlist Process

Extensions on Liquid Protocol are rare exceptions, not a standard pathway. The default position is that no new extensions will be added.

## Current Extensions

The following extensions are deployed and allowlisted at launch. All are covered by the [0xMacro](https://0xmacro.com/library/audits/clanker-3) and [Cantina](https://cantina.xyz/portfolio/e4db23cd-f46d-4d99-adca-a60941b44f65) audits of the Clanker v4 codebase, from which Liquid Protocol is forked.

| Extension | Address |
|-----------|---------|
| LiquidAirdropV2 | `0x1423974d48f525462f1c087cBFdCC20BDBc33CdD` |
| LiquidVault | `0xdFCCC93257c20519A9005A2281CFBdF84836d50E` |
| LiquidUniv4EthDevBuy | `0x5934097864dC487D21A7B4e4EEe201A39ceF728D` |
| LiquidUniv3EthDevBuy | `0x376028cfb6b9A120E24Aa14c3FAc4205179c0025` |
| LiquidPresaleEthToCreator | `0x3bca63EcB49d5f917092d10fA879Fdb422740163` |
| LiquidPresaleAllowlist | `0xCBb4ccC4B94E23233c14759f4F9629F7dD01f10B` |

## Applying for a New Extension

New extensions are only considered if all of the following conditions are met:

1. **Full audit** — The extension must be audited by a recognized third-party firm prior to submission.
2. **Uniswap alignment** — Given direct interaction with Uniswap v4 pool architecture, we look for alignment with contacts at Uniswap or approval from a core contributor through their standard hook submission process.
3. **Internal review** — The Liquid Protocol engineering lead must review and approve the extension.
4. **Admin Safe approval** — Final enablement requires a multisig transaction through the Liquid Protocol admin Gnosis Safe (`0x872c561f699B42977c093F0eD8b4C9a431280c6c`). No single party can unilaterally add an extension.

To apply, email **slaterg@mog.capital** and **admin@mog.capital** with your audit report and extension contract address.

## On-Chain Mechanism

Extension allowlisting is managed by the `LiquidPoolExtensionAllowlist` contract (`0xb614167d79aDBaA9BA35d05fE1d5542d7316Ccaa`), which controls per-pool extension permissions and is owned by the admin Safe above. No admins are currently set on this contract.

Liquid Protocol reserves the right to remove any extension at any time.

## Current Status

We have no plans to approve additional extensions at this time. Any extension approvals under consideration will be communicated in advance with all partners and infrastructure providers.
