# Session Handoff — Tempo Mainnet Deployment

**Last session:** 2026-04-04 / 2026-04-07 / 2026-04-08
**Branch target:** `deploy/tempo-mainnet` (not yet created — Task 1)
**Status:** Brainstorming + planning complete. No code written yet.

## Quick Context

Deploying Liquid Protocol V0 on Tempo Mainnet (chain ID 4217). Tempo is a USD-denominated L1 with no native ETH. We're using **pathUSD** (`0x20C0000000000000000000000000000000000000`) as the quote token in place of WETH.

**Deployment scope:** Core + hooks + 2 extensions (airdrop, vault) + LP locker. **Skipped:** ETH-dependent extensions (dev buy V3/V4, presale, presale allowlist), all MEV modules (Tempo has no MEV infra — ~500ms deterministic finality).

**Key insight:** No Solidity changes. WETH is an immutable constructor param — we just pass pathUSD instead.

## Documents

| File | Purpose |
|------|---------|
| `docs/superpowers/specs/2026-04-04-tempo-mainnet-deploy-design.md` | Approved design spec |
| `docs/superpowers/plans/2026-04-04-tempo-mainnet-deploy.md` | 19-task implementation plan |

## Plan Status — 19 Tasks

### Phase A: Code/Config (no external dependencies — can start immediately)
- [ ] Task 1: Create branch + restore Base scripts from git `2a8452e`
- [ ] Task 2: Create `.env.tempo` template
- [ ] Task 3: Update `foundry.toml` with Tempo explorer config
- [ ] Task 4: Write `script/tempo/00_DeploySafe.s.sol` (blocked by @gs for Safe owners/threshold input, but script itself can be written)
- [ ] Task 5: Write `script/tempo/02_DeployExtensions.s.sol` (Tempo subset)
- [ ] Task 6: Write `script/tempo/04_ConfigureAllowlists.s.sol`
- [ ] Task 7: Write `script/tempo/05_TransferOwnership.s.sol`
- [ ] Task 8: Full build verification (`forge build`, `forge test`, `forge fmt --check`)
- [ ] Task 9: Update README with Tempo section (placeholders)

### Phase B: Operational (all blocked on @gs)
- [ ] Task 10: **@gs** — bridge USDC Base→Tempo via Stargate, swap to pathUSD
- [ ] Task 11: **@gs** — provide Safe owners/threshold + run `00_DeploySafe.s.sol`
- [ ] Task 12: **@gs** — Phase 0 core deployment
- [ ] Task 13: **@gs** — Phase 1 hooks deployment (CREATE2 salt mining)
- [ ] Task 14: **@gs** — Phase 2 Tempo extensions deployment
- [ ] Task 15: **@gs** — Phase 3b LP locker deployment
- [ ] Task 16: **@gs** — Phase 4 allowlist configuration
- [ ] Task 17: **@gs** — Phase 5 ownership transfer (irreversible, verify Safe first)
- [ ] Task 18: Verify all contracts on Tempo explorer
- [ ] Task 19: Update README with final addresses, push branch

## Next Session Goals

**Primary:** Complete Phase A (Tasks 1-9) — all code/config work.

**Execution mode:** Subagent-driven (fresh subagent per task, review between).

**Parallel opportunity:** While code work happens, ping @gs for:
1. Safe owner addresses + threshold (blocks Task 11)
2. Bridge timing for Task 10
3. Confirmation they have deployer key access for Tasks 12-17

## Key Addresses (reference — also in spec)

**Tempo Mainnet (chain 4217):**
- RPC: `https://rpc.tempo.xyz`
- Explorer: `https://explore.tempo.xyz`
- pathUSD (quote): `0x20C0000000000000000000000000000000000000`
- V4 PoolManager: `0x33620f62c5b9b2086dd6b62f4a297a9f30347029`
- V4 PositionManager: `0x3fc79444f8eacc1894775493ff3fa41f1e35ce11`
- UniversalRouter: `0xa2dc7d0266f0cc50b3eeaf36c9bfcecff1beea91`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`
- V3 SwapRouter: `0x6a3988d2366ad79917a2399f18a1a82b157470e1`
- Safe v1.4.1 Singleton: `0x41675C099F32341bf84BFc5382aF534df5C7461a`
- Safe ProxyFactory: `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`

**Stargate (for bridging):**
- Base Pool (EID 30184): `0x27a16dc786820B16E5c9028b75B99F6f604b5d26`
- Tempo USDC.e: `0x20C000000000000000000000b9537d11c60E8b50`
- Tempo StargateOFTUSDC: `0x8c76e2F6C5ceDA9AA7772e7efF30280226c44392`
- Tempo LZ EndpointV2: `0x20Bb7C2E2f4e5ca2B4c57060d1aE2615245dCc9C`
- Tempo LZ Endpoint ID: `30410`

## Open Items / Risks

1. **Linear tickets not yet created** — MCP server was disconnected last session. If reconnected next session, create project + tickets mapping to plan tasks (store `linearIssueId` in TaskCreate metadata so the `TaskCompleted` hook auto-syncs).
2. **Safe UI unavailable on Tempo** — must manage multisig via CLI/scripts until `app.safe.global` adds Tempo support.
3. **Explorer verification API** — `https://explore.tempo.xyz/api` URL format unconfirmed, may need adjustment when first verifying (Task 18).
4. **Foundry + Tempo fee model** — Tempo requires TIP-20 stablecoin for gas (not native). `forge script --broadcast` behavior on Tempo untested. First deployment (Task 12) will reveal if any flags are needed.
5. **pathUSD decimal mismatch** — 6 decimals vs WETH's 18. Protocol math handles this but pool pricing math/UX needs awareness.

## Hook Setup

`TaskCompleted` agent hook is live in `.claude/settings.local.json` — when a task with `linearIssueId` metadata completes, it calls `mcp__plugin_linear_linear__save_issue` to mark the issue Done. Requires `/hooks` to have been opened once (done last session).

## Memory References

Saved memories relevant to this work:
- `reference_tempo_uniswap_addresses.md` — all Tempo addresses
- `project_liquid_tempo_deployment.md` — project status
- `reference_uniswap_api.md` — Uniswap API key note

## How to Resume

1. Read this file, the spec, and the plan
2. Check if Linear MCP is reconnected — if yes, create project + tickets first
3. Message @gs to request Safe owner list + threshold and confirm bridge timing
4. Dispatch subagent for Task 1 and proceed through Phase A (Tasks 1-9)
5. Park Phase B until @gs confirms readiness
