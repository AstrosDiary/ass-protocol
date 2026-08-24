#!/usr/bin/env bash
# verify-stack.sh — verify + proxy-link the whole $ASS stack from broadcast JSONs.
# Prereqs: .env with ETHERSCAN_API_KEY; run after DeployBasket/DeployCore/DeploySatellites.
set -uo pipefail   # no -e: verification is retry-friendly, keep going on per-contract failures
cd "$(dirname "$0")/.."
set -a; source .env; set +a

SRC_OF() {
  case "$1" in
    AssBasket)         echo "src/basket/AssBasket.sol:AssBasket";;
    AssVault)          echo "src/vault/AssVault.sol:AssVault";;
    AssVaultFactory)   echo "src/vault/AssVaultFactory.sol:AssVaultFactory";;
    AssEngine)         echo "src/engine/AssEngine.sol:AssEngine";;
    AssSwapExecutor)   echo "src/adapters/AssSwapExecutor.sol:AssSwapExecutor";;
    AssDistributor)    echo "src/distributor/AssDistributor.sol:AssDistributor";;
    AssTriggerAdapter) echo "src/adapters/AssTriggerAdapter.sol:AssTriggerAdapter";;
    AssViews)          echo "src/views/AssViews.sol:AssViews";;
    UpgradeableBeacon) echo "lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon";;
    BeaconProxy)       echo "lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol:BeaconProxy";;
    *) echo "";;
  esac
}

verify_one() {  # name addr arg0 arg1
  local NAME="$1" ADDR="$2" A0="${3:-}" A1="${4:-}"
  local SRC; SRC=$(SRC_OF "$NAME"); [ -z "$SRC" ] && { echo "   skip (unknown): $NAME $ADDR"; return; }
  local ARGS=()
  case "$NAME" in
    UpgradeableBeacon)               ARGS=(--constructor-args "$(cast abi-encode "constructor(address,address)" "$A0" "$A1")");;
    BeaconProxy)                     ARGS=(--constructor-args "$(cast abi-encode "constructor(address,bytes)" "$A0" "$A1")");;
    AssVaultFactory)                 ARGS=(--constructor-args "$(cast abi-encode "constructor(address,address)" "$A0" "$A1")");;
    AssViews)                        ARGS=(--constructor-args "$(cast abi-encode "constructor(address,address,address)" "$A0" "$A1" "${5:?views arg2}")");;
  esac
  echo "== verify $NAME $ADDR"
  forge verify-contract "$ADDR" "$SRC" --chain bsc --watch "${ARGS[@]}" || echo "   RETRY LATER: $NAME $ADDR"
}

for BC in broadcast/DeployBasket.s.sol/56/run-latest.json \
          broadcast/DeployCore.s.sol/56/run-latest.json \
          broadcast/DeploySatellites.s.sol/56/run-latest.json; do
  [ -f "$BC" ] || { echo "missing $BC — skipping"; continue; }
  echo "==== $BC"
  while IFS=$'\t' read -r NAME ADDR A0 A1; do
    verify_one "$NAME" "$ADDR" "$A0" "$A1"
  done < <(jq -r '.transactions[] | select(.transactionType=="CREATE")
                  | [.contractName, .contractAddress, (.arguments[0] // ""), (.arguments[1] // "")] | @tsv' "$BC")
done

echo "==== proxy-link (BscScan API)"
for P in "$BASKET" "$ENGINE" "$EXEC" "$DIST" "$ADAPTER"; do
  echo -n "link $P : "
  curl -s "https://api.etherscan.io/v2/api?chainid=56&module=contract&action=verifyproxycontract&address=$P&apikey=$ETHERSCAN_API_KEY" \
    -d "" | jq -r '.result // .message'
  sleep 1
done
echo "(links are async; spot-check one proxy page for Read-as-Proxy. UI fallback: Contract tab -> More Options -> Is this a proxy.)"