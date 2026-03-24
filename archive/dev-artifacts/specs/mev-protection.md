# Liquid Protocol — MEV Protection

> TODO: Document MEV protection mechanisms.

## Topics to Cover

- `LiquidSniperAuctionV2` — auction-based sniper protection with descending fees
- `LiquidMevDescendingFees` — parabolic fee decay (up to 80% initial, max 2 min duration)
- `LiquidSniperUtilV2` — utility for interacting with sniper auctions
- How MEV modules are initialized via hooks after pool creation
- Comparison with V0 auction design (removed)
