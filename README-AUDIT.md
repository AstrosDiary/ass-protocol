# $ASS Protocol — Flap Vault Audit Package (v6 — all 16 findings closed)

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
| AssBasket (IB-ASS) | `0xA37e75827B46B80BF8B0e88883Dd395e1A5bDDFc` | `0x9E0E5Fa9106238286568f4c7371DDd55Df9bEeA3` |
| AssEngine | `0xb7FCD7f4418BB3285B51bCFEB6e784884667c297` | `0x1B4d28d2fe431B5C69c48B3CCc065b3042676BF9` |
| AssSwapExecutor | `0x45477488270CEB3599aeE10926d3E05B52b1Fc3e` | `0xD1151aC6C094995564Db40dcc3E6F0C34D709D52` |
| AssTriggerAdapter | `0x2A93588631623E5982834ECFb4770019a12AF5D9` | `0x8f8658F92605285aec03f095571195aE73E7186F` |
| AssVault implementation | `0x941f92C9b83557c2276D5dc554Fd6e7B67441FA0` | beacon `0x0237E8c3A26f6B7a6C05B6C34D43e19A380227d3` |
| AssVaultFactory (v2.3, computed dividend) | `0x52EB388BD4ee370dc510e1E21057d91056990620` | — |

All five beacons are Guardian-owned from construction. `engine.distributor()`
returns the AssBasket at rest (battery-verified). Nothing has launched through
this factory; the real $ASS launch will be its first and only token.

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