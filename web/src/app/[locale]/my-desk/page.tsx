"use client";
import { useEffect, useState } from "react";
import { useTranslations } from "next-intl";
import { useAccount, useConnect } from "wagmi";
import { STOCKS, fmtUnits, formatBStockAmount, shortAddr } from "@/lib/ass";
import { useWallet, useHolderCard, useAssetCards, useClaim, useMarkets, usd, pct } from "@/lib/hooks";

export default function MyDesk() {
  const t = useTranslations("folio");
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { data: w } = useWallet(mounted && isConnected ? address : undefined);
  const { data: card } = useHolderCard(mounted && isConnected ? address : undefined);
  const { data: cards } = useAssetCards();
  const { data: markets } = useMarkets();
  const { claim, signing, mining, isSuccess, txHash, error } = useClaim(address);

  const connected = mounted && isConnected && address;

  /* ---------- disconnected shell (spec: structure, never blank) ---------- */
  if (!connected) {
    return (
      <div className="mx-auto max-w-7xl px-4 py-16">
        <h1 className="font-display text-4xl font-bold tracking-tight text-cream">{t("title")}</h1>
        <p className="mt-3 max-w-md text-warm-white/80">{t("connectSub")}</p>
        <button onClick={() => connect({ connector: connectors[0] })}
          className="mt-6 rounded-lg bg-deep-purple px-6 py-3 font-display text-cream transition-colors hover:bg-ass-purple">
          {t("connectCta")}
        </button>
        <div className="mt-10 grid gap-4 opacity-40 md:grid-cols-3">
          {[t("kpiClaimable"), t("kpiPosition"), t("kpiStatus")].map((l) => (
            <div key={l} className="rounded-xl border border-warm-white/10 bg-midnight p-5">
              <div className="text-[11px] tracking-widest text-muted-grey">{l}</div>
              <div className="mt-1.5 font-mono text-2xl text-warm-white">—</div>
            </div>
          ))}
        </div>
      </div>
    );
  }

  /* ---------- connected ---------- */
  const assBal = (w?.[3]?.result as bigint | undefined) ?? null;
  const share = (w?.[4]?.result as readonly [bigint, bigint, bigint] | undefined)?.[0] ?? null;
  const minShare = (w?.[5]?.result as bigint | undefined) ?? null;
  const eligible = share != null && share > 0n;

  const claimable = card?.claimableShares ?? null;           // 1e18-per-USD at accrual
  const preview = STOCKS.map((s) => {
    const i = card?.assets.findIndex((a) => a.toLowerCase() === s.address.toLowerCase()) ?? -1;
    return i >= 0 ? (card!.claimAmountsRaw[i] as bigint) : null;
  });
  const oraclePrice = (addr: string): number | null => {
    const c = cards?.find((x) => x.asset.toLowerCase() === addr.toLowerCase());
    if (!c || c.priceUsd1e18 === 0n) return null;          // 0 = stale feed -> dash
    return Number(c.priceUsd1e18) / 1e18;
  };
  const claimableUsd = claimable == null ? null
    : Number(fmtUnits(claimable, 18, 6).replace(/,/g, ""));
  const hasClaim = claimable != null && claimable > 0n;
  const busy = signing || mining;

  return (
    <div className="mx-auto max-w-7xl px-4 py-10">
      <h1 className="font-display text-4xl font-bold tracking-tight text-cream">{t("title")}</h1>

      {/* status strip — system parameters, not ad copy */}
      <div className={`mt-6 flex flex-wrap items-center justify-between gap-3 rounded-md border px-4 py-3 font-mono text-sm ${
        eligible ? "border-gain/25 bg-gain/5" : "border-warm-white/10 bg-midnight"}`}>
        <span className={eligible ? "text-gain" : "text-muted-grey"}>
          ● {eligible ? t("statusActive") : t("statusBelow")}
        </span>
        <span className="text-muted-grey tabular">
          {t("eligibility")} ≥ {minShare != null ? fmtUnits(minShare, 18, 5) : "10,000"} $ASS
          <span className="ml-4">{t("yourShare")}: {share != null ? fmtUnits(share) : "—"}</span>
        </span>
      </div>

      {/* summary */}
      <div className="mt-6 grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-warm-white/10 bg-warm-white/10 md:grid-cols-3">
        {[
          { label: t("kpiClaimable"), value: claimableUsd == null ? "—" : usd(claimableUsd) },
          { label: t("kpiPosition"), value: assBal != null ? fmtUnits(assBal) : "—" },
          { label: t("kpiWallet"), value: shortAddr(address) },
        ].map((k) => (
          <div key={k.label} className="bg-midnight px-5 py-4">
            <div className="text-[11px] tracking-widest text-muted-grey">{k.label}</div>
            <div className="mt-1.5 font-mono text-2xl text-warm-white tabular">{k.value}</div>
          </div>
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[60fr_40fr]">
        {/* claimable bStocks — the unwrap preview */}
        <div className="rounded-xl border border-warm-white/10 bg-midnight p-5">
          <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">{t("claimableTitle")}</h2>
          <table className="mt-3 w-full font-mono text-sm tabular">
            <thead>
              <tr className="text-left text-[11px] tracking-widest text-muted-grey">
                <th className="py-2 font-normal">{t("thAsset")}</th>
                <th className="py-2 text-right font-normal">{t("thPrice")}</th>
                <th className="py-2 text-right font-normal">{t("th24h")}</th>
                <th className="py-2 text-right font-normal">{t("thClaimable")}</th>
                <th className="py-2 text-right font-normal">{t("thValue")}</th>
              </tr>
            </thead>
            <tbody>
              {STOCKS.map((s, i) => {
                const m = markets?.stocks[s.symbol];
                const p = oraclePrice(s.address) ?? m?.priceUsd ?? null; // oracle first, dex fallback
                const b = preview[i];
                const v = b != null && p != null
                  ? Number(formatBStockAmount(b).replace(/,/g, "")) * p : null;
                return (
                  <tr key={s.symbol} className="border-t border-warm-white/5">
                    <td className="py-3"><span className="text-warm-white">{s.symbol}</span>
                      <span className="ml-2 hidden text-xs text-muted-grey md:inline">{s.name}</span></td>
                    <td className="py-3 text-right text-warm-white/85">{usd(p)}</td>
                    <td className={`py-3 text-right ${m?.change24h == null ? "text-muted-grey" : m.change24h >= 0 ? "text-gain" : "text-loss"}`}>
                      {m?.change24h == null ? "—" : pct(m.change24h)}</td>
                    <td className="py-3 text-right text-warm-white/85">{b != null ? formatBStockAmount(b) : "—"}</td>
                    <td className="py-3 text-right text-warm-white/85">{v == null ? "—" : usd(v)}</td>
                  </tr>
                );
              })}
            </tbody>          
          </table>
          <p className="mt-3 font-mono text-xs text-muted-grey">{t("claimableNote")}</p>
        </div>

        {/* claim panel (replaces accrual feed, same box) */}
        <div className="rounded-md border border-term-border bg-term-bg p-5">
          <h2 className="font-mono text-xs tracking-[0.25em] text-term-dim">{t("claimTitle")}</h2>
          <div className="mt-4 font-mono">
            <div className="text-[11px] tracking-widest text-term-dim">{t("claimAvailable")}</div>
            <div className="mt-1 text-3xl text-warm-white tabular">
              {claimableUsd == null ? "—" : usd(claimableUsd)}
            </div>
            <div className="mt-1 text-xs text-term-dim">{t("claimAtAccrual")}</div>

            <button
              onClick={() => claim()}
              disabled={!hasClaim || busy}
              className={`mt-5 w-full rounded-lg px-6 py-3 font-display text-cream transition-colors ${
                hasClaim && !busy
                  ? "cursor-pointer bg-deep-purple hover:bg-ass-purple"
                  : "cursor-not-allowed bg-warm-white/10 text-muted-grey"}`}>
              {signing ? t("claimSigning") : mining ? t("claimMining") : t("claimCta")}
            </button>

            {isSuccess && txHash && (
              <a href={`https://bscscan.com/tx/${txHash}`} target="_blank" rel="noreferrer"
                className="mt-3 block text-center text-xs text-gain hover:underline">
                {t("claimDone")} ↗
              </a>
            )}
            {error && (
              <p className="mt-3 text-center text-xs text-loss">{t("claimError")}</p>
            )}
            {!hasClaim && !busy && !isSuccess && (
              <p className="mt-3 text-center text-xs tracking-widest text-term-dim">{t("claimEmpty")}</p>
            )}
            <p className="mt-5 border-t border-term-border pt-3 text-[11px] leading-relaxed text-term-dim">
              {t("claimExplainer")}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}