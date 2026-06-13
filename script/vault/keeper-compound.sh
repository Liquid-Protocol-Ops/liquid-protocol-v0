#!/usr/bin/env bash
#
# keeper-compound.sh — quote-then-relay wrapper for the wstDIEM keeper.
#
# Each run: reads the keeper's USDC, skips below a threshold (cron-safe), pulls a
# FRESH Uniswap QuoterV2 quote for USDC→WETH→DIEM, derives a minDiemOut floor net
# of slippage, then runs KeeperRelay.s.sol against the given adapter. The minDiemOut
# (MOG-541) makes the swap revert rather than route into a sandwich — so this is safe
# to schedule on a tight interval without hand-quoting each time.
#
# Usage:
#   ./script/vault/keeper-compound.sh
#
# Env (all optional; sensible defaults):
#   ADAPTER       venue adapter to route through   (default: v6 SurplusAdapter)
#   AMOUNT        USDC (6dec) to relay             (default: full keeper balance)
#   MIN_USDC      skip if balance below this 6dec  (default: 5000000 = $5)
#   SLIPPAGE_BPS  floor = quote × (1 - bps/1e4)    (default: 200 = 2%)
#   BASE_RPC_URL  RPC endpoint                     (default: https://mainnet.base.org)
#   KEEPER_PK     keeper private key               (default: ~/.splits/config.json key.privateKey)
#   DRY_RUN=1     simulate only (no --broadcast)
#
# Cron example (hourly, log appended):
#   0 * * * * /path/to/liquid-protocol-v0/script/vault/keeper-compound.sh >> ~/keeper-compound.log 2>&1
#
set -uo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
RPC="${BASE_RPC_URL:-https://mainnet.base.org}"
ADAPTER="${ADAPTER:-0x91b3E39Ef6335D97876AdB4448A998c7cbD3885F}"   # v6 SurplusAdapter
SLIPPAGE_BPS="${SLIPPAGE_BPS:-200}"                                 # 2%
MIN_USDC="${MIN_USDC:-5000000}"                                     # $5 (6dec)
QUOTER="${QUOTER:-0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a}"      # Uniswap V3 QuoterV2 (Base)
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006

CAST="$HOME/.foundry/bin/cast"
FORGE="$HOME/.foundry/bin/forge"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { echo "[keeper-compound $(date -u +%H:%M:%S)] $*"; }
die() { echo "[keeper-compound ERROR] $*" >&2; exit 1; }

# Retry a read-only call up to 5× — public RPCs intermittently 401/rate-limit.
# For unattended cron, set BASE_RPC_URL to a dedicated endpoint (Alchemy/QuickNode).
rd() { local i out; for i in 1 2 3 4 5; do out="$("$@" 2>/dev/null)"; [ -n "$out" ] && { printf '%s' "$out"; return 0; }; sleep 3; done; return 1; }

# ── Keeper key + address ────────────────────────────────────────────────────
if [ -z "${KEEPER_PK:-}" ]; then
  KEEPER_PK="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.splits/config.json')))['key']['privateKey'])")" \
    || die "could not read KEEPER_PK from ~/.splits/config.json"
fi
keeper="$("$CAST" wallet address --private-key "$KEEPER_PK")" || die "bad KEEPER_PK"
log "keeper=$keeper adapter=$ADAPTER"

# ── 1) Balance gate (cron-safe: clean exit below threshold) ─────────────────
bal="$(rd "$CAST" call "$USDC" "balanceOf(address)(uint256)" "$keeper" --rpc-url "$RPC" | grep -oE '^[0-9]+')"
[ -n "$bal" ] || die "could not read keeper USDC balance"
amount="${AMOUNT:-$bal}"
log "keeper USDC=$bal  relay=$amount  (threshold=$MIN_USDC, 6dec)"
if [ "$amount" -lt "$MIN_USDC" ]; then
  log "below threshold — nothing to do."; exit 0
fi
[ "$amount" -le "$bal" ] || die "AMOUNT ($amount) exceeds keeper balance ($bal)"

# ── 2) Adapter sanity: uses USDC, registered on its vault ────────────────────
au="$(rd "$CAST" call "$ADAPTER" "usdc()(address)" --rpc-url "$RPC")"
[ "$(echo "$au" | tr 'A-Z' 'a-z')" = "$(echo "$USDC" | tr 'A-Z' 'a-z')" ] || die "adapter usdc mismatch ($au)"
vault="$(rd "$CAST" call "$ADAPTER" "vault()(address)" --rpc-url "$RPC")"
reg="$(rd "$CAST" call "$vault" "isVenueAdapter(address)(bool)" "$ADAPTER" --rpc-url "$RPC")"
[ "$reg" = "true" ] || die "adapter $ADAPTER is not registered on vault $vault (isVenueAdapter=false)"

# ── 3) Fresh quote → minDiemOut floor ───────────────────────────────────────
f1="$(rd "$CAST" call "$ADAPTER" "usdcWethFee()(uint24)" --rpc-url "$RPC" | grep -oE '^[0-9]+')"
f2="$(rd "$CAST" call "$ADAPTER" "diemFee()(uint24)"    --rpc-url "$RPC" | grep -oE '^[0-9]+')"
diem="$(rd "$CAST" call "$vault" "asset()(address)" --rpc-url "$RPC")"
strip() { echo "${1#0x}"; }
path="0x$(strip "$USDC")$(printf '%06x' "$f1")$(strip "$WETH")$(printf '%06x' "$f2")$(strip "$diem")"
quote="$(rd "$CAST" call "$QUOTER" "quoteExactInput(bytes,uint256)(uint256,uint160[],uint32[],uint256)" \
        "$path" "$amount" --rpc-url "$RPC" 2>/dev/null | head -1 | grep -oE '^[0-9]+')"
[ -n "$quote" ] && [ "$quote" -gt 0 ] || die "quote failed (path/pool liquidity?) path=$path amount=$amount"
min="$(python3 -c "print(int($quote) * (10000 - $SLIPPAGE_BPS) // 10000)")"
log "quote=$quote DIEM(18dec)  minDiemOut=$min  (@${SLIPPAGE_BPS}bps floor)"

# ── 4) Relay (KeeperRelay.s.sol: approve → receiveSettlement → routeYield) ───
BROADCAST="--broadcast"; [ "${DRY_RUN:-0}" = "1" ] && BROADCAST=""
( cd "$REPO_ROOT" && \
  ADAPTER="$ADAPTER" AMOUNT="$amount" MIN_DIEM_OUT="$min" KEEPER_PK="$KEEPER_PK" \
  "$FORGE" script script/vault/KeeperRelay.s.sol --tc KeeperRelay --rpc-url "$RPC" $BROADCAST ) \
  || die "KeeperRelay failed"
log "done."
