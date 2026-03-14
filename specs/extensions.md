# Liquid Protocol — Extensions

> TODO: Document the extension system.

## Topics to Cover

- Extension interface (`ILiquidExtension`) and `receiveTokens()` lifecycle
- `LiquidVault` — token locking with timed release
- `LiquidAirdropV2` — merkle-based airdrops with mutable root and admin controls
- `LiquidUniv4EthDevBuy` / `LiquidUniv3EthDevBuy` — dev buys at launch
- `LiquidPresaleEthToCreator` / `LiquidPresaleAllowlist` — presale mechanics
- Supply allocation rules: max 10 extensions, max 90% (9000 bps)
- Extension ordering: vault → airdrop → devBuy → presale (presale must be last)
