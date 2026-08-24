#!/usr/bin/env bash
# =============================================================================
# $ASS postlaunch v2 — basket era
# Run IMMEDIATELY after the Flap UI launch. Wires vault->engine->basket,
# arms the TriggerAdapter, deploys Views, verifies everything with read-backs.
# Prereqs in .env: LOGS_RPC BSC_RPC_URL BASKET ENGINE EXEC ADAPTER FACTORY
#                  DEPLOYER QQQB WBNB SMART_ROUTER
# Usage:  ./postlaunch.sh <LAUNCH_TX_HASH>
# Aborts on ANY mismatch. Safe to re-run (sends are idempotent or no-op-guarded).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

TX="${1:?usage: ./postlaunch.sh <launch tx hash>}"
SIGN=(--rpc-url "$LOGS_RPC" --account ass-deployer --password-file "$HOME/.ass_pw")
R=(--rpc-url "$BSC_RPC_URL")

say()  { printf '\n\033[1;35m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m   OK  %s\033[0m\n' "$*"; }
die()  { printf '\033[0;31m   FAIL %s\033[0m\n' "$*"; exit 1; }
# read-back helper: expect <description> <expected> <actual>
expect() { [ "$(echo "$3" | tr 'A-F' 'a-f')" = "$(echo "$2" | tr 'A-F' 'a-f')" ] && ok "$1 = $3" || die "$1: expected $2 got $3"; }

# -------- Phase A: derive launch artifacts from the receipt ------------------
say "Phase A — derive TOKEN / VAULT / DIV from $TX"
LAUNCH_BLOCK=$(cast receipt "$TX" blockNumber "${R[@]}")
T0=$(cast keccak "VaultCreated(address,address,address)")
VAULT=0x$(cast receipt "$TX" --json "${R[@]}" | jq -r --arg t0 "$T0" '[.logs[] | select(.topics[0]==$t0)][0].topics[1]' | cut -c 27-)
TOKEN=0x$(cast receipt "$TX" --json "${R[@]}" | jq -r --arg t0 "$T0" '[.logs[] | select(.topics[0]==$t0)][0].topics[2]' | cut -c 27-)
[ ${#VAULT} -eq 42 ] || die "VAULT derivation (VaultCreated topic1)"
[ ${#TOKEN} -eq 42 ] || die "TOKEN derivation (VaultCreated topic2)"
DIV=$(cast call "$TOKEN" "dividendContract()(address)" "${R[@]}")
ok "TOKEN=$TOKEN"; ok "VAULT=$VAULT"; ok "DIV=$DIV"; ok "LAUNCH_BLOCK=$LAUNCH_BLOCK"

say "Phase A.1 — THE resolver proof (portal wired the basket at birth)"
expect "DIV.dividendToken" "$BASKET" "$(cast call "$DIV" "dividendToken()(address)" "${R[@]}")"
expect "vault.taxToken"    "$TOKEN"  "$(cast call "$VAULT" "taxToken()(address)" "${R[@]}")"
expect "vault.quote"       "$QQQB"   "$(cast call "$VAULT" "vaultQuoteToken()(address)" "${R[@]}")"

# -------- Phase B: wiring trio ----------------------------------------------
say "Phase B — wiring: basket.taxToken, vault.engine, engine.distributor"
if [ "$(cast call "$BASKET" "taxToken()(address)" "${R[@]}")" = "0x0000000000000000000000000000000000000000" ]; then
  cast send "$BASKET" "setTaxToken(address)" "$TOKEN" --gas-limit 100000 "${SIGN[@]}" >/dev/null
fi
cast send "$VAULT" "setEngine(address)" "$ENGINE" --gas-limit 100000 "${SIGN[@]}" >/dev/null
cast send "$ENGINE" "setDistributor(address)" "$BASKET" --gas-limit 100000 "${SIGN[@]}" >/dev/null
expect "basket.taxToken"    "$TOKEN"  "$(cast call "$BASKET" "taxToken()(address)" "${R[@]}")"
expect "vault.engine"       "$ENGINE" "$(cast call "$VAULT" "engine()(address)" "${R[@]}")"
expect "engine.distributor" "$BASKET" "$(cast call "$ENGINE" "distributor()(address)" "${R[@]}")"

# -------- Phase C: adapter arming -------------------------------------------
say "Phase C — arm the TriggerAdapter"
cast send "$ENGINE" "setKeeper(address,bool)" "$ADAPTER" true --gas-limit 80000 "${SIGN[@]}" >/dev/null
cast send "$ENGINE" "setKeeper(address,bool)" "$DEPLOYER" true --gas-limit 80000 "${SIGN[@]}" >/dev/null   # manual fallback mandate
cast send "$ENGINE" "setGasFund(address,uint16)" "$ADAPTER" 100 --gas-limit 80000 "${SIGN[@]}" >/dev/null
cast send "$ADAPTER" "setVault(address)" "$VAULT" --gas-limit 80000 "${SIGN[@]}" >/dev/null
cast send "$VAULT" "grantRole(bytes32,address)" "$(cast keccak "OPERATOR_ROLE")" "$ADAPTER" --gas-limit 100000 "${SIGN[@]}" >/dev/null
cast send "$ADAPTER" "setSwapRouter(address)" "$SMART_ROUTER" --gas-limit 80000 "${SIGN[@]}" >/dev/null
expect "engine.keeper(adapter)"  "true"     "$(cast call "$ENGINE" "keeper(address)(bool)" "$ADAPTER" "${R[@]}")"
expect "engine.gasFund"          "$ADAPTER" "$(cast call "$ENGINE" "gasFund()(address)" "${R[@]}")"
expect "adapter.vault"           "$VAULT"   "$(cast call "$ADAPTER" "vault()(address)" "${R[@]}")"
expect "vault OPERATOR(adapter)" "true"     "$(cast call "$VAULT" "hasRole(bytes32,address)(bool)" "$(cast keccak "OPERATOR_ROLE")" "$ADAPTER" "${R[@]}")"

# -------- Phase D: routes (discovered 2026-08-22; 600k gas REQUIRED) --------
say "Phase D — routes: QQQB -100- USDT -2500- {BABAB,TSMB,SKHYB}; gas QQQB -500- WBNB"
USDT=0x55d398326f99059fF775485246999027B3197955
BABAB=0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec
TSMB=0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c
SKHYB=0xCA750eF65f295BBECd685Abf54e82CAf297BDB61
P_QU=0xe531fcb1F5a195de7608B9F4f9518544C2cdB693
P_UB=0xfD95CB1391999006Eb91797a7c62acFe88b20292
P_UT=0x03f59988F5c366046321cCcD2BF0E3878e2ed69C
P_US=0xD7d30F434b12F7Ed9b0Ae11fF1C754745a10aD52
P_QW=0x47BC06722295AC316A569EEF87aC32FAA455F441
F100=0x000064; F500=0x0001f4; F2500=0x0009c4

cast send "$ADAPTER" "setRoute(address,address[],address[],bytes)" "$BABAB" "[$P_QU,$P_UB]" "[$QQQB,$USDT,$BABAB]" "$(cast concat-hex "$QQQB" $F100 "$USDT" $F2500 "$BABAB")" --gas-limit 600000 "${SIGN[@]}" >/dev/null
cast send "$ADAPTER" "setRoute(address,address[],address[],bytes)" "$TSMB"  "[$P_QU,$P_UT]" "[$QQQB,$USDT,$TSMB]"  "$(cast concat-hex "$QQQB" $F100 "$USDT" $F2500 "$TSMB")"  --gas-limit 600000 "${SIGN[@]}" >/dev/null
cast send "$ADAPTER" "setRoute(address,address[],address[],bytes)" "$SKHYB" "[$P_QU,$P_US]" "[$QQQB,$USDT,$SKHYB]" "$(cast concat-hex "$QQQB" $F100 "$USDT" $F2500 "$SKHYB")" --gas-limit 600000 "${SIGN[@]}" >/dev/null
cast send "$ADAPTER" "setGasRoute(address[],address[],bytes)" "[$P_QW]" "[$QQQB,$WBNB]" "$(cast concat-hex "$QQQB" $F500 "$WBNB")" --gas-limit 400000 "${SIGN[@]}" >/dev/null

# LAUNCH params: 15-min cycle, 5-min TWAP, 5% slippage (micro pools; cap bounds abuse ~\$28/buy)
cast send "$ADAPTER" "setParams(uint64,uint32,uint16,uint256,uint256,uint256)" 900 300 500 1000000000000000 5000000000000000 5000000000000000 --gas-limit 80000 "${SIGN[@]}" >/dev/null

Q_B=$(cast call "$ADAPTER" "twapQuoteExt(address,uint256)(uint256)" "$BABAB" 1000000000000000000 "${R[@]}" --json | jq -r '.[0]')
Q_T=$(cast call "$ADAPTER" "twapQuoteExt(address,uint256)(uint256)" "$TSMB"  1000000000000000000 "${R[@]}" --json | jq -r '.[0]')
Q_S=$(cast call "$ADAPTER" "twapQuoteExt(address,uint256)(uint256)" "$SKHYB" 1000000000000000000 "${R[@]}" --json | jq -r '.[0]')
Q_G=$(cast call "$ADAPTER" "gasTwapQuoteExt(uint256)(uint256)" 1000000000000000000 "${R[@]}" --json | jq -r '.[0]')
for q in "$Q_B" "$Q_T" "$Q_S" "$Q_G"; do
  [ "$q" != "1000000000000000000" ] && [ "$q" != "0" ] || die "route quote came back as echo/zero — route not set"
done
ok "TWAP quotes live: BABAB=$Q_B TSMB=$Q_T SKHYB=$Q_S gas=$Q_G"

# -------- Phase E: fuel + ignition ------------------------------------------
say "Phase E — fund adapter + schedule first cycle"
cast send "$ADAPTER" --value 50000000000000000 --gas-limit 40000 "${SIGN[@]}" >/dev/null
cast send "$ADAPTER" "scheduleCycle(uint64)" 0 --gas-limit 250000 "${SIGN[@]}" >/dev/null
ok "0.05 BNB seeded; first CYCLE requested"

# -------- Phase F: Views ------------------------------------------------------
say "Phase F — deploy AssViews v3"
VIEWS=$(forge create src/views/AssViews.sol:AssViews "${SIGN[@]}" --broadcast --json --constructor-args "$VAULT" "$ENGINE" "$BASKET" | jq -r '.deployedTo')
expect "views.dividendContract" "$DIV" "$(cast call "$VIEWS" "dividendContract()(address)" "${R[@]}")"

# -------- Phase G: summary ----------------------------------------------------
say "postlaunch v2 COMPLETE — append to .env:"
cat <<EOF
TOKEN=$TOKEN
VAULT=$VAULT
DIV=$DIV
VIEWS=$VIEWS
LAUNCH_BLOCK=$LAUNCH_BLOCK
EOF
cat <<'EOF'

REMAINING MANUAL:
 1. .env: paste block above; re-source.
 2. Verify Views on BscScan (forge verify-contract ... AssViews --constructor-args ...).
 3. WEB: update web .env.local (TOKEN/VAULT/DIVIDEND/BASKET/ENGINE/VIEWS) -> deploy to Netlify.
 4. Watch one full autonomous cycle (5 reads) before announcing.
 5. Post-observation: nothing else. No keeper. No cron. It runs itself.
EOF