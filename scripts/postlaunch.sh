#!/usr/bin/env bash
# $ASS post-launch automation: derive -> wire -> VERIFY -> battery -> views.
# Usage: ./scripts/postlaunch.sh <TOKEN_ADDRESS> <LAUNCH_TX_HASH>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

TOKEN=$1; TX=$2
RPC=$BSC_RPC_URL
SIGN=(--rpc-url "$RPC" --account ass-deployer --password-file "$HOME/.ass_pw")
R=(--rpc-url "$RPC")
lower() { tr '[:upper:]' '[:lower:]'; }
eq() { [ "$(echo "$1" | lower)" = "$(echo "$2" | lower)" ]; }
die() { echo "FATAL: $*" >&2; exit 1; }

echo "== PHASE A: derive =="
LAUNCH_BLOCK=$(cast receipt "$TX" blockNumber "${R[@]}")
T0=$(cast keccak "VaultCreated(address,address,address)")
VAULT_TOPIC=$(cast receipt "$TX" --json "${R[@]}" \
  | jq -r --arg t0 "$T0" '[.logs[] | select(.topics[0] == $t0)][0].topics[1] // empty')
[ -n "$VAULT_TOPIC" ] || die "no VaultCreated event in tx $TX — is this really the launch tx?"
VAULT=0x${VAULT_TOPIC: -40}
DIV=$(cast call "$TOKEN" "dividendContract()(address)" "${R[@]}")

echo "TOKEN=$TOKEN"; echo "VAULT=$VAULT"; echo "DIV=$DIV"; echo "LAUNCH_BLOCK=$LAUNCH_BLOCK"

echo "== sanity: the vault really is ours and really is this token's =="
eq "$(cast call "$VAULT" "taxToken()(address)" "${R[@]}")" "$TOKEN" || die "vault.taxToken != TOKEN"
eq "$(cast call "$VAULT" "vaultQuoteToken()(address)" "${R[@]}")" "$QQQB" || die "vault quote != QQQB"

echo "== PHASE B: wire =="
cast send "$VAULT" "setEngine(address)" "$ENGINE" --gas-limit 100000 "${SIGN[@]}" >/dev/null
cast send "$DIST" "setDividendTracker(address)" "$DIV" --gas-limit 100000 "${SIGN[@]}" >/dev/null

echo "== PHASE B: read-back verification (the 2026-08-20 lesson) =="
eq "$(cast call "$VAULT" "engine()(address)" "${R[@]}")" "$ENGINE" || die "vault.engine read-back mismatch"
eq "$(cast call "$DIST" "dividendTracker()(address)" "${R[@]}")" "$DIV" || die "dist.dividendTracker read-back mismatch"
echo "wiring verified on-chain"

echo "== PHASE C: battery =="
echo "buyTax:    $(cast call "$TOKEN" "buyTaxRate()(uint16)" "${R[@]}")   (expect 300)"
echo "sellTax:   $(cast call "$TOKEN" "sellTaxRate()(uint16)" "${R[@]}")   (expect 300)"
echo "minShare:  $(cast call "$DIV" "minimumShareBalance()(uint256)" "${R[@]}")   (expect 10000e18)"
echo "assets:    $(cast call "$ENGINE" "assetsCount()(uint256)" "${R[@]}")   (expect 3)"
MIN_PROCESS=${MIN_PROCESS:-15000000000000000}   # 0.015 QQQB launch default; override via env
cast send "$ENGINE" "setMinProcessAmount(uint256)" "$MIN_PROCESS" --gas-limit 60000 "${SIGN[@]}" >/dev/null
echo "minProcessAmount set: $MIN_PROCESS"

echo "== PHASE D: views =="
VAULT=$VAULT DIV=$DIV forge script script/DeployViews.s.sol --rpc-url "$RPC" --account ass-deployer --broadcast --slow >/dev/null
VIEWS=$(jq -r '[.transactions[] | select(.contractName=="AssViews")][0].contractAddress' broadcast/DeployViews.s.sol/56/run-latest.json)

echo ""
echo "== DONE — paste into .env (WSL + VPS) and web/.env.local =="
echo "TOKEN=$TOKEN"; echo "VAULT=$VAULT"; echo "DIV=$DIV"; echo "VIEWS=$VIEWS"; echo "LAUNCH_BLOCK=$LAUNCH_BLOCK"
echo ""
echo "REMAINING MANUAL: [1] VPS: edit .env (+ INDEXER_START=START_BLOCK=$LAUNCH_BLOCK), rm keeper/*state*.json, sourced pm2 restart --update-env"
echo "                  [2] web/.env.local swap -> build -> gates -> deploy   [3] same-day BscScan verify: vault proxy + views"