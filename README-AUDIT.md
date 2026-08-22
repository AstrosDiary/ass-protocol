# $ASS Protocol — Flap Vault Audit Package (v2 — post-feedback addendum)

**Asian Stock Strategy ($ASS)** — a Flap Tax Token V3 (QQQB-quoted) whose custom
vault converts trading-tax revenue (QQQB) into a basket of Binance bStocks
(BABAB, TSMB, SKHYB) automatically distributed pro-rata to eligible holders.

## v2 changes (audit feedback, all implemented)

1. **Upgrade authority → Guardian.** Vault beacon ownership transferred to the
   official BSC Guardian. All four satellites redeployed as BeaconProxies with
   their beacons **constructed Guardian-owned** (no transfer step to trust).
2. **onlyOwnerOrGuardian** on every admin/rescue function of Engine, Executor,
   Distributor, and TriggerAdapter (Guardian as parallel emergency caller;
   day-to-day ownership unchanged). Vault already carried the AccessControl
   equivalent per VaultBase mandate.
3. **Satellites upgradeable.** Engine, Executor, Distributor, TriggerAdapter
   each: implementation + Guardian-owned UpgradeableBeacon + BeaconProxy.
   Initializer pattern throughout (`_disableInitializers` on impls; all
   former declaration-site defaults moved into `initialize()`).
4. **Flap Trigger Service integration** (new `AssTriggerAdapter`) — swap
   pipeline fully automated; details below.
5. **maxSpendPerBuy reduced to 0.5 QQQB** per feedback.

## Deployed contracts (BSC mainnet, all verified)

| Contract | Proxy | Beacon (owner: Guardian) |
|---|---|---|
| AssEngine | `0x91c396376ee37f99e6aa34b59a3a055d98de7eb4` | `0x24F63159f84D75E89cb8B111B3d38513173222c7` |
| AssSwapExecutor | `0xaeac4478fd937700861a5af6067907248ddd2892` | `0xF9BA4B17148a4592bd3e07784486983cc2fc7Fa1` |
| AssDistributor | `0x032f8b7220c4cfab5b2d888855ae0a7b55400550` | `0x31103d437e35555be7fcc88E415A1BE576F78a5a` |
| AssTriggerAdapter | `0xe6d45e3b88e79d33c4b19b0c1877777b09829918` | `0x4012Ab06f7476EbE0Bb4e6D71946C5632e5f2218` |

| Vault stack | Address |
|---|---|
| AssVault implementation | `<VAULT_IMPL>` |
| Vault beacon (owner: Guardian) | `<VAULT_BEACON>` |
| AssVaultFactory (v2.3) | `<FACTORY>` |

(BscScan proxy linking done — Read/Write-as-Proxy resolves to the
implementations on all four satellite proxies.)

## Architecture & revenue flow

TRADE ($ASS) → 3% tax (QQQB) → **AssVault** (BeaconProxy, spec V3) →
`release()` → **AssEngine** (weight-split budgets, 1% automation-gas skim) →
TWAP-priced buys via **AssSwapExecutor** (allowlisted router) → bStocks land in
**AssDistributor** → paginated snapshot/payout cycles pay holders per Flap
Dividend tracker shares. Cycle cadence + buys driven by **AssTriggerAdapter**
through the Flap Trigger Service; the manual keeper retains every role as a
full fallback.

- **AssVault** — minimal audited surface. Holds ONLY QQQB. VaultBaseV3:
  balance-delta accounting (`accountedQuote`), `receive()` ping target (native
  value reverts), permissionless `sync()`, `release()` operator-gated with
  fixed destination (engine).
- **AssVaultFactory** — spec v2.3, BeaconProxy deployer, UI-launchable by any
  team. `onBeforeLaunch` pins: quote == QQQB, non-zero total trade tax,
  vaultBps > 0, dividendBps == 0 (tracker-only), TOKEN_TAXED_V3.
- **AssEngine** — splits released QQQB into per-asset budgets by weight bps
  (processing takes balance-minus-earmarked; re-processing can never
  double-count; cumulative counts allocated only). Optional gas skim
  (`gasFundBps`, hard-capped 3%, currently 1%) funds the adapter's fee tank
  from tax revenue. Keeper role = timing + routes only; failed buys are
  isolated (try/catch self-call) and budgets carry forward.
- **AssSwapExecutor** — validates calldata by invariant, not content:
  allowlisted router, exact approve + reset, zero native value, output
  measured as own balance delta vs raw-unit minOut, fixed recipient
  (distributor), deadline fence.
- **AssDistributor** — INDEX-pattern paginated cycles. Keeper submits
  ADDRESSES only (strictly ascending); shares read LIVE from the Flap tracker
  at submit AND payout — pays min(snapshot, live). Coverage >= 90% of tracker
  totalShares or finalize reverts. Dust accrues + auto-flushes; failed
  transfers re-accrue; registered assets never sweepable.
- **AssTriggerAdapter** — ITriggerReceiver per the integration requirements:
  mandatory sender check; requestId → action binding consumed on execute (no
  replay); LIVE re-validation inside every callback (delay-aware); reentrancy
  guard; per-asset BUY callbacks sized well under the gas cap; minOut from
  Pancake V3 TWAP (vendored canonical FullMath/TickMath/consult, configurable
  window + slippage). **Fail-soft doctrine: the callback never reverts** —
  unmet conditions skip with events; a drained fee tank emits FundingLow and
  automation lapses to the manual keeper, never halting revenue. Fee tank
  funded from the engine skim via TWAP-bounded QQQB→WBNB→BNB conversion.
  Documented exception: the WBNB `withdraw` in the top-up leg is not
  soft-wrapped — canonical WBNB backs a just-received balance 1:1, so the
  revert path exists only against a non-canonical WBNB.
  Distribution cycles remain keeper-driven: the holder set is indexed
  off-chain from share events and is not computable inside a callback.

## Trust model

- Owner (deployer, later multisig): asset registration/weights, router
  allowlist, keeper mgmt, thresholds, adapter params/routes. Cannot touch
  holder funds or basket assets.
- Keeper (manual fallback + adapter): timing + route selection only. Every
  economically meaningful value is computed or verified on-chain.
- Flap Guardian: beacon upgrade authority on vault + all four satellites;
  parallel emergency caller on all satellite admin; irrevocable vault roles.
- Flap Trigger Service: schedules callbacks only — the adapter re-validates
  everything and trusts nothing about timing.

## Tests

`forge test` — **64 tests / 6 suites, all green**: unit (vault+factory
pinning incl. V3 ping/balance-delta, engine/executor failure isolation,
distributor ledger laws), fuzz (weight splits), invariants (solvency,
conservation), full E2E (tax → release → process → 4-asset buys incl.
router-down carry-forward/catch-up → 3000-holder paginated cycle →
multiplier shift mid-pipeline), and a dedicated Trigger integration suite
against a faithful service mock (sender check, replay protection, delay-aware
re-validation, fail-soft paths incl. vault-revert and TWAP-unavailable,
owner-loud/callback-soft funding split, fee-tank top-up, skim accounting,
initializer locks, guardian authority). BEP-677: all accounting raw units.

## Build

Foundry, solc 0.8.26. OpenZeppelin v5.7.0 (contracts + upgradeable, aligned).
`remappings.txt` included; deps via forge install.