# $ASS Protocol — v8 — all findings closed; launch stack)

**Asian Stock Strategy ($ASS)** — a Flap Tax Token V3 (QQQB-quoted) whose custom
vault pipeline converts trading-tax revenue into a basket of Binance bStocks
(BABAB, TSMB, SKHYB) credited automatically to eligible holders and claimable
on demand.

## v4: all five challenge-review actions implemented in code, stack redeployed

1. **Vault emergency controls (Rule-009)** — `emergencyWithdrawNative` /
   `emergencyWithdrawToken` added to AssVault: Guardian-gated (owner/admin
   cannot call — preserves the minimal-custody trust model), `nonReentrant`,
   evented. No accounting re-baseline needed: all vault views derive from live
   `QUOTE.balanceOf` + `totalReleased`.
2. **Adapter enabled-check** — the CYCLE BUY-spawn loop and `_runBuy` both
   re-validate `assets[a].enabled` live and skip disabled assets (spawn loop
   skips BEFORE paying a Trigger Service fee), closing the recurring fee-bleed
   path on disabled-but-funded assets.
3. **AssDistributor physically deleted** from the source tree (contract, its
   test suites, and its deploy wiring). The engine's buy-delivery target
   (`engine.distributor()`) is wired to the AssBasket at deploy time and
   verified at rest by our pre-launch battery.
4. **Staleness ceiling** — `setMaxFeedAge` now bounds to `[5 minutes, 24 hours]`
   (previously floor-only), closing the unbounded-staleness gap in the
   oracle-config finding.
5. **executeBuy Guardian parity** — the engine's `onlyKeeper` set now includes
   the Guardian, restoring the oversight parity the round-4 TWAP finding
   identified as missing.

Also in v4: adapter fund sweeps are now **pause-gated in code** (revert
`NotPaused` unless the adapter is paused — decommission-only, matching the
documented trust model), and `previewMint` mirrors `processReceived`'s
post-drain recovery branch in the source tree (the deployed basket instance
carries the v3 view — no redeploy warranted, as `previewMint` has no on-chain
or frontend consumer and the divergence is view-only in the transient
post-drain state, per the round-3 disposition).

**v6 (round-6 #15):** zero-spend-cap assets now skip soft in both the BUY
spawn loop (before any Trigger Service fee is paid) and `_runBuy` — the same
pattern as the disabled-asset guard — and the adapter's cap semantics now
match the engine's exactly (`maxSpendPerBuy == 0` means never buy, on both
sides). Satellites (engine / executor / adapter) redeployed with this guard;
addresses below are current and battery-verified at rest, including
`engine.distributor()` → basket.

**v7 (round-7 WBNB finding):** the WBNB unwrap in _topUpGas is now try/catch soft-fail (a failed unwrap holds WBNB for the next cycle instead of failing the callback), and MockWBNB forwards real WBNB's 2,300-gas transfer stipend so this class is caught locally. Live-path analysis: the unwrap only executes inside trigger(), which enters through the proxy, so the beacon slot and implementation are EIP-2929-warm when the stipend fires — verified by a live on-chain GasToppedUp from staging (tx in reply).

**Claims are atomic by design (final disposition of round-1 F5):** a claim
either delivers all basket components or reverts whole with the entitlement
intact and retriable — confirmed in the challenge review for the self-serve
`withdrawDividendsFor` path, which is the only claim surface our web app and
any first-party courier use. A deliver-what-you-can unwrap was evaluated and
rejected: it would add partial-claim states, a credit ledger, and extra
external calls inside the claim transfer hook to serve a scenario requiring a
transfer-restricted bStock (none of the three components restrict transfers;
every live claim across three staging generations delivered in full).

## Deployed contracts (BSC mainnet, all verified, proxies linked)

| Contract | Proxy | Beacon (owner: Flap Guardian) |
|---|---|---|
| AssBasket (IB-ASS) | `0x6F5ec32738425A95ef14CE195d0860f36CE35985` | `0xD0B140d75AB3C914e82440064E8170fF197aA72f` |
| AssEngine | `0xA58Ac75117f39dd911496f55aeD04748ca51a1C4` | `0x8733F76Db6A8d39D7a681f5FE074863b8c7805cC` |
| AssSwapExecutor | `0xc1695cDB9f544845355c96E179B95A198a561E31` | `0xADEfb9e53a468Cd1Fb72e95fd845092Bf6b23F2f` |
| AssTriggerAdapter | `0x9B430ec599ca16dE2d9596b42ae34A683E48575f` | `0xB2627f02B96AaCe75e97149E56fcB110c1C20d31` |
| AssVault implementation | `0xE7bB89c6590B52fA87bA2eb899813cF5A328D6B6` | beacon `0x6FA21108C86Db77Da8018E7e74F71C3153227C9d` |
| AssVaultFactory (v2.3, computed dividend) | `0x5f80d78Eb439F473cdde43b5F08c35AB383F6F07` | — |

All five beacons are Guardian-owned from construction. `engine.distributor()`
returns the AssBasket at rest (battery-verified). Nothing has launched through
this factory; the real $ASS launch will be its first and only token.

**v8:** identical v7 source (zero code delta — standard-JSON input unchanged)
redeployed in full from a fresh launch-operations deployer EOA
(`0xfF274879d79CB1f86FFC4176A0BC880CA16E5c71`). Addresses above are current;
battery-verified at rest including `engine.distributor()` → basket. Factory
constructor args: (vaultBeacon `0xB3E3...50d7`, basket `0xDA19...128e`).

**v9:** identical source (zero code delta — the standard-JSON input remains
exact) redeployed in full from the final launch deployer EOA
(`0xe8EE1133217D83eaCd9BaA1cBd0fa95B8051ec7e`). Addresses above are current;
battery-verified at rest including `engine.distributor()` → basket. Factory
constructor args: (vaultBeacon `0x6FA2...7C9d`, basket `0x6F5e...5985`).

## Revenue flow (all on-chain, no keeper in the money path)

TRADE ($ASS) → 3% tax (QQQB) → **AssVault** → `release()` → **AssEngine**
(weight-split budgets; configured 1% gas skim — hard-capped at 3% in code —
self-funds automation) → TWAP-bounded
buys via **AssSwapExecutor** → bStocks pool in **AssBasket** →
`processReceived()` NAV-mints IB-ASS shares + deposits into **Flap Dividend**
→ every eligible holder credited instantly → claim (self or on-behalf)
auto-unwraps to BABAB/TSMB/SKHYB in the wallet. Claims are atomic:
all components deliver or the claim reverts whole, entitlement intact.
Cycles driven by **AssTriggerAdapter** on the Flap Trigger Service; fail-soft
throughout; a manual keeper fallback exists for engine timing only and can
never touch entitlements.

## Trust model

- Owner (launcher EOA, later multisig): pre-entitlement economic configuration —
  asset weights, router allowlist, thresholds, adapter routes/params, and the
  basket's oracle config (feed ids within the single Atlas hub; staleness bound
  code-bounded to [5 minutes, 24 hours]). These shape how FUTURE mints are
  priced. The owner cannot touch holder funds, pooled basket assets, or
  existing entitlements: once shares are minted and deposited, distribution and
  claims run entirely on the Flap Dividend contract. Adapter fund sweeps are
  pause-gated in code (decommission-only) and touch only the adapter's own gas
  tank — the BNB seed and fee skim — never user funds, pooled basket assets,
  or entitlements.
- Flap Guardian: beacon upgrade authority on all five beacons; parallel
  emergency caller (`onlyOwnerOrGuardian`) on satellite admin; sole caller of
  the vault's emergency withdrawals; included in the engine's keeper set for
  buy-path oversight parity.
- Flap Dividend: sole authority on shares and claims (native, audited).
- Flap Trigger Service: scheduling only; every callback re-validates live.

## Tests

`forge test` — **67 tests, all green**: vault/factory pinning (incl. v2.3
resolver + sentinel validation), engine/executor isolation, basket suite
(NAV mint math incl. price-move proportionality and BEP-677 scaling, staleness
reverts, deposit gates against a source-faithful Flap Dividend mock,
auto-unwrap pro-rata, **processed-pool-only claim basis**, **post-drain
recovery**), Trigger integration suite (sender check, replay, delay-aware
re-validation, fail-soft paths, strict router-calldata decode, pause-gated
sweeps), and fuzz coverage. Plus the mainnet-fork suite under `FORK_RPC_URL`:
live Atlas feeds, Flap Dividend reference semantics against the live ElonCoin
deployment, Trigger Service params, real-pool TWAP, and basket NAV math on
real oracle data.

## Staging validation (mainnet, throwaway launches through this exact stack lineage)

Three full rehearsals culminating in: UI launch → portal resolved the basket
into the Dividend **in the launch tx** → autonomous Trigger cycles (release,
process, buys, mint, deposit; gas tank self-refueled from the skim) →
multi-holder pro-rata claims through the production web UI delivering all
three bStocks in one transaction. Two implementation bugs were found by
rehearsal and fixed with regression tests before this lineage's final form:
(a) claims pay strictly from the processed pool (an early claimer could
previously sweep not-yet-minted deposits); (b) share pricing recovers at
parity after a full pool drain (previously could deadlock minting against
residual supply). The v6 stack carries both fixes plus all five
challenge-review actions and the round-6 zero-cap guard; happy to share
tx-level exhibits.

## Build

Foundry, solc 0.8.26. OpenZeppelin v5.7.0 (contracts + upgradeable). Vendored:
Flap factory/vault interfaces, Atlas `IPriceHub` (BUSL-1.1 header retained).
`remappings.txt` included.