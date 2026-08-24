# $ASS Protocol — Flap Vault Audit Package (v3 — basket migration per reviewer guidance)

**Asian Stock Strategy ($ASS)** — a Flap Tax Token V3 (QQQB-quoted) whose custom
vault pipeline converts trading-tax revenue into a basket of Binance bStocks
(BABAB, TSMB, SKHYB) credited automatically to eligible holders and claimable
on demand.

## v3: both review items implemented exactly as recommended

**1. Mainnet-fork test coverage** — new `test/MainnetFork.t.sol` (runs under
`FORK_RPC_URL`): live Atlas Oracle reads from a contract call-frame for all
three feeds (freshness asserted), Flap Dividend reference semantics verified
against the live ElonCoin deployment (dividendToken wiring, setShare gating,
permissionless withdraw surface), Trigger Service fee/gas-cap reads, V3 TWAP
against the real QQQB pool, and our basket's NAV math against the real oracle.

**2. Centralization of Snapshot → Holder Submission → Payout — ELIMINATED by
adopting the recommended basket-token pattern** (docs: basket-token-multi-asset-
dividends), following the reference deployment (IB-ElonCoin) verified on-chain:

- **AssDistributor and its keeper role are GONE from the money path.** No
  snapshots, no holder submission, no off-chain indexing, no payout cycles, no
  privileged payout functions for anyone — owner or Guardian.
- **Flap's own Dividend contract does all share accounting and claims** — the
  same audited contract every Flap dividend token uses, updated on every
  transfer via `setShare`. Entitlements accrue instantly and proportionally at
  deposit (MasterChef accumulator); claiming is fully permissionless self-serve
  (`withdrawDividendsFor(user)`, callable by anyone for anyone).
- **New `AssBasket` (IB-ASS)** implements the tutorial's index-basket token:
  oracle-NAV proportional minting (Atlas push feeds, staleness-bounded,
  BEP-677 multiplier-aware), MINIMUM_LIQUIDITY ratio lock, and the
  `_transfer`-hook auto-unwrap — a claim burns the shares and delivers the
  underlying bStocks pro-rata straight to the holder's wallet in the same
  transaction. Holders never see or hold the basket token.
- **Launch wiring is fully automatic**: the factory implements v2.3
  `resolveDividendToken` (returns the basket); the UI passes
  MAGIC_DIVIDEND_COMPUTED and the portal wires the Dividend to the basket
  inside the launch transaction itself — proven live (see exhibits).
- `processReceived()` (mint + deposit) is **permissionless**; the Trigger
  adapter pokes it each cycle but nobody is trust-critical to distribution.

## Deployed contracts (BSC mainnet, all verified, proxies linked)

| Contract | Proxy | Beacon (owner: Flap Guardian) |
|---|---|---|
| AssBasket (IB-ASS) | `0xd2742cE3e18C860248382E99326D025EBf316824` | `0xc87e8f9bE6248E31Dd8412539f6095dB4882319e` |
| AssEngine | `0x3182F228618797D6c08b2f3B32114B9F6F0253b9` | `0x22c5Ff5860cCfd885347e2daf89E6F0fBC9f6EAd` |
| AssSwapExecutor | `0x7ed322Ac2Ff5c1B4b3843ba00a30ee943E67FA3f` | `0x8ca1d98A4327fA40f35Bf18A787edCFb749c607E` |
| AssTriggerAdapter | `0xBB4c75246BF68483303aAEf3911260447254676A` | `0x81C6C07E0c4d2cC8B872F0Ec3C8C650b42274085` |
| AssVault implementation | `0xbc885dbB77Ebf2ed117f109b65F3728F3948e4B8` | beacon `0xD1909A198abE8692D472442d7179590bC6892bA6` |
| AssVaultFactory (v2.3, computed dividend) | `0xd1096d1886e6034c63b4b621D268eE6AE201D1f0` | — |

(AssDistributor remains in the repo for history and is deployed-unwired at
`0xf576949E8D7CAd44bd1E85B6Abf0831318b4e16d`; nothing references it.)

## Revenue flow (all on-chain, no keeper in the money path)

TRADE ($ASS) → 3% tax (QQQB) → **AssVault** → `release()` → **AssEngine**
(weight-split budgets; configured 1% gas skim — hard-capped at 3% in code —
self-funds automation) → TWAP-bounded
buys via **AssSwapExecutor** → bStocks pool in **AssBasket** →
`processReceived()` NAV-mints IB-ASS shares + deposits into **Flap Dividend**
→ every eligible holder credited instantly → claim (self or on-behalf)
auto-unwraps to BABAB/TSMB/SKHYB in the wallet. Cycles driven by
**AssTriggerAdapter** on the Flap Trigger Service; fail-soft throughout; a
manual keeper fallback exists for engine timing only and can never touch
entitlements.

## Trust model

- Owner (launcher EOA, later multisig): asset weights, router allowlist,
  thresholds, adapter routes/params. Cannot touch holder funds, pooled basket
  assets, or entitlements. Adapter fund sweeps (owner/Guardian) touch only the
  adapter's own gas tank — the BNB seed and fee skim — never user funds,
  pooled basket assets, or entitlements; a pause-gate on sweeps is queued for
  the next adapter implementation.
- Flap Guardian: beacon upgrade authority on all six beacons; parallel
  emergency caller (`onlyOwnerOrGuardian`) on satellite admin.
- Flap Dividend: sole authority on shares and claims (native, audited).
- Flap Trigger Service: scheduling only; every callback re-validates live.

## Tests

`forge test` — **91 tests, all green**: vault/factory pinning (incl. v2.3
resolver + sentinel validation), engine/executor isolation, basket suite
(NAV mint math incl. price-move proportionality and BEP-677 scaling, staleness
reverts, deposit gates against a source-faithful Flap Dividend mock,
auto-unwrap pro-rata, **processed-pool-only claim basis**, **post-drain
recovery**), Trigger integration suite (sender check, replay, delay-aware
re-validation, fail-soft paths, strict router-calldata decode), fuzz +
invariants + E2E. Plus the mainnet-fork suite (item 1) under `FORK_RPC_URL`.

## Staging validation (mainnet, throwaway launches through this exact stack lineage)

Three full rehearsals culminating in: UI launch → portal resolved the basket
into the Dividend **in the launch tx** → autonomous Trigger cycles (release,
process, buys, mint, deposit; gas tank self-refueled from the skim) →
multi-holder pro-rata claims through the production web UI delivering all
three bStocks in one transaction. Two implementation bugs were found by
rehearsal and fixed with regression tests before this final stack: (a) claims
now pay strictly from the processed pool (an early claimer could previously
sweep not-yet-minted deposits); (b) share pricing recovers at parity after a
full pool drain (previously could deadlock minting against residual supply).
The final stack carries both fixes; happy to share tx-level exhibits.

## Build

Foundry, solc 0.8.26. OpenZeppelin v5.7.0 (contracts + upgradeable). Vendored:
Flap factory/vault interfaces, Atlas `IPriceHub` (BUSL-1.1 header retained).
`remappings.txt` included.