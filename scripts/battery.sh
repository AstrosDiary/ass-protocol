#!/usr/bin/env bash
# battery.sh — post-deploy sanity battery for the $ASS stack (pre-launch state).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
R=(--rpc-url "$BSC_RPC_URL")
GUARDIAN=0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b

echo "factorySpecVersion      : $(cast call "$FACTORY" "factorySpecVersion()(string)" "${R[@]}")   [expect v2.3]"
echo "factory.BASKET          : $(cast call "$FACTORY" "BASKET()(address)" "${R[@]}")   [expect $BASKET]"
echo "resolveDividendToken    : $(cast call "$FACTORY" "resolveDividendToken(address,uint8,bytes)(address)" 0x0000000000000000000000000000000000000001 6 0x "${R[@]}")   [expect $BASKET]"
echo "isQuoteTokenSupported   : $(cast call "$FACTORY" "isQuoteTokenSupported(address)(bool)" "$QQQB" "${R[@]}")   [expect true]"
echo "basket.oracleDecimals   : $(cast call "$BASKET" "oracleDecimals()(uint8)" "${R[@]}")   [expect 18]"
echo "basket.totalNavUsd      : $(cast call "$BASKET" "totalNavUsd()(uint256)" "${R[@]}")   [expect 0 pre-launch]"
echo "basket.taxToken         : $(cast call "$BASKET" "taxToken()(address)" "${R[@]}")   [expect 0x0 pre-launch]"
echo "engine.assetsCount      : $(cast call "$ENGINE" "assetsCount()(uint256)" "${R[@]}")   [expect 3]"
echo "engine.gasFund          : $(cast call "$ENGINE" "gasFund()(address)" "${R[@]}")   [expect $ADAPTER]"
echo "engine.minProcessAmount : $(cast call "$ENGINE" "minProcessAmount()(uint256)" "${R[@]}")   [expect 25000000000000000]"
echo "engine.keeper(adapter)  : $(cast call "$ENGINE" "keeper(address)(bool)" "$ADAPTER" "${R[@]}")   [expect true]"
echo "engine.keeper(deployer) : $(cast call "$ENGINE" "keeper(address)(bool)" "$DEPLOYER" "${R[@]}")   [expect true]"
echo "exec.routerAllowed(SR)  : $(cast call "$EXEC" "routerAllowed(address)(bool)" "$SMART_ROUTER" "${R[@]}")   [expect true]"
echo "adapter.cycleInterval   : $(cast call "$ADAPTER" "cycleInterval()(uint64)" "${R[@]}")   [expect 900]"
echo "adapter.swapRouter      : $(cast call "$ADAPTER" "swapRouter()(address)" "${R[@]}")   [expect $SMART_ROUTER]"
echo "adapter balance         : $(cast balance "$ADAPTER" "${R[@]}")   [expect ~50000000000000000]"
echo "-- beacon owners (expect Guardian x6) --"
grep -oE '0x[0-9a-fA-F]{40}' <<< "$(grep -i beacon .env)" | sort -u | while read -r B; do
  echo "  $B : $(cast call "$B" "owner()(address)" "${R[@]}" 2>/dev/null || echo 'not a beacon (comment noise)')"
done