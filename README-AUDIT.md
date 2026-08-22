# $ASS Protocol — Flap Vault Audit Package

**Asian Stock Strategy ($ASS)** — a Flap Tax Token V3 (QQQB-quoted) whose custom
vault converts trading-tax revenue (QQQB) into a basket of Binance bStocks
(BABAB, TSMB, SKHYB) automatically distributed pro-rata to eligible holders.

## Deployed contracts (BSC mainnet, verified)

| Contract | Address |
|---|---|
| AssVault implementation | `0xE65Bf825c6F3e51527f7213858536Ef94b419e8C` |
| UpgradeableBeacon | `0xf4f624D4657F8226801C97fEf72ed8976Fb0F12c` |
| AssVaultFactory (v2.3) | `0x9dB0f0De7d661203109d711747F6ee905F4FD3e3` |
| AssEngine | `0xF9A09De3caCf56997e7B00CFF8CAbe2A42AF9440` |
| AssSwapExecutor | `0xefE75E602dE3502fcA102479cc2D102e5317e8a0` |
| AssDistributor | `0x6Ab786C434C06020C31f4F8c1E39bA3231F01ba7` |

Beacon upgrade authority will be transferred to the Flap Guardian
(`0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`) as part of this submission.

## Architecture & revenue flow

TRADE ($ASS) → 3% tax (QQQB) → **AssVault** (BeaconProxy, spec V3) →
`release()` → **AssEngine** (weight-split budgets) → keeper-priced buys via
**AssSwapExecutor** (allowlisted router) → bStocks land in **AssDistributor** →
paginated snapshot/payout cycles pay holders per Flap Dividend tracker shares.

- **AssVault** — minimal audited surface. Holds ONLY the quote token (QQQB).
  V3 balance-delta accounting: `receive()` is the TaxProcessor ping target
  (zero-value; native value reverts), `sync()` permissionless recognition,
  `accountedQuote` baseline decremented on every outflow. `release()` is
  operator-gated and can only send to the configured engine.
- **AssVaultFactory** — spec v2.3 (`factorySpecVersion()`), deploys
  BeaconProxies. `onBeforeLaunch` pins: quote == QQQB, non-zero total trade
  tax, vaultBps > 0, dividendBps == 0 (tracker-only), TOKEN_TAXED_V3.
  Launchable by any team through the Flap UI.
- **AssEngine** — splits released QQQB into per-asset budgets by weight bps
  (≤ 10000; processing takes only balance-minus-earmarked, so re-processing
  can never double-count). Keeper supplies only routes/prices, never amounts.
  Failed buys are isolated (try/catch self-call) and budgets carry forward.
- **AssSwapExecutor** — validates keeper calldata by invariant, not content:
  allowlisted router, exact approve + reset, zero native value, output
  measured as own balance delta vs raw-unit minOut, fixed recipient
  (distributor), deadline fence.
- **AssDistributor** — INDEX-pattern paginated cycles. Keeper submits holder
  ADDRESSES only (strictly ascending; shares read live from the Flap Dividend
  tracker at submit AND payout — pays min(snapshot, live)). Coverage check
  (>= 90% of tracker totalShares) or finalize reverts. Sub-minimum amounts
  accrue and auto-flush; failed transfers re-accrue, never revert a batch.
  Registered assets can never be swept by anyone, including the owner.

## Trust model

- Owner (deployer, later multisig): asset registration/weights, executor and
  router allowlist, thresholds. Cannot touch holder funds or basket assets.
- Keeper: timing + route selection only. Every economically meaningful value
  (amounts, minOut, recipients, shares) is computed or verified on-chain.
- Flap Guardian: full vault role backup (irrevocable by anyone else) + beacon
  upgrade authority after transfer.

## Tests

`forge test` — 49 tests / 5 suites, all green: unit (vault+factory pinning,
engine/executor incl. failure isolation, distributor ledger laws), fuzz
(weight splits), invariants (solvency: balance >= reserved; conservation),
and a full E2E (tax → release → process → 4-asset buys incl. one-router-down
carry-forward/catch-up → 3000-holder paginated cycle → multiplier shift
mid-pipeline). BEP-677: all accounting raw units; display multiplier is
frontend-only.

## Build

Foundry, solc 0.8.26. `remappings.txt` included; dependencies:
OpenZeppelin Contracts + Upgradeable (via forge install).