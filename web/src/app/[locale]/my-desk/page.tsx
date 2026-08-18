"use client";
import { useEffect, useState } from "react";
import { useAccount, useConnect } from "wagmi";
import { STOCKS, ADDR, fmtUnits, formatBStockAmount, shortAddr } from "@/lib/ass";
import { useWallet, useHolderHistory, useHolderCard, useMarkets, usd, pct } from "@/lib/hooks";

const stockBy = (a: string) => STOCKS.find((s) => s.address.toLowerCase() === a.toLowerCase());

export default function MyDesk() {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { data: w } = useWallet(mounted && isConnected ? address : undefined);
  const { data: hist } = useHolderHistory(mounted && isConnected ? address : undefined);
  const { data: card } = useHolderCard(mounted && isConnected ? address : undefined);
  const { data: markets } = useMarkets();

  const connected = mounted && isConnected && address;

  /* ---------- disconnected shell (spec: structure, never blank) ---------- */
  if (!connected) {
    return (
      <div className="mx-auto max-w-7xl px-4 py-16">
        <h1 className="font-display text-4xl font-bold tracking-tight text-cream">YOUR ASIA DESK</h1>
        <p className="mt-3 max-w-md text-warm-white/80">
          Connect your wallet to view your $ASS position and automatically accrued Asian bStocks.
        </p>
        <button onClick={() => connect({ connector: connectors[0] })}
          className="mt-6 rounded-lg bg-deep-purple px-6 py-3 font-display text-cream transition-colors hover:bg-ass-purple">
          CONNECT WALLET
        </button>
        <div className="mt-10 grid gap-4 opacity-40 md:grid-cols-3">
          {["AUTO-ACCRUED BASKET VALUE", "$ASS POSITION", "ACCRUAL STATUS"].map((l) => (
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
  const stockBals = STOCKS.map((_, i) => (w?.[i]?.result as bigint | undefined) ?? null);
  const assBal = (w?.[3]?.result as bigint | undefined) ?? null;
  const share = (w?.[4]?.result as readonly [bigint, bigint, bigint] | undefined)?.[0] ?? null;
  const minShare = (w?.[5]?.result as bigint | undefined) ?? null;
  const eligible = share != null && share > 0n;

  const basketUsd = (() => {
    if (!markets) return null;
    let sum = 0;
    for (let i = 0; i < STOCKS.length; i++) {
      const b = stockBals[i]; const p = markets.stocks[STOCKS[i].symbol]?.priceUsd;
      if (b == null || p == null) return null;
      sum += Number(formatBStockAmount(b).replace(/,/g, "")) * p;
    }
    return sum;
  })();

  return (
    <div className="mx-auto max-w-7xl px-4 py-10">
      <h1 className="font-display text-4xl font-bold tracking-tight text-cream">YOUR ASIA DESK</h1>

      {/* status strip — system parameters, not ad copy */}
      <div className={`mt-6 flex flex-wrap items-center justify-between gap-3 rounded-md border px-4 py-3 font-mono text-sm ${
        eligible ? "border-gain/25 bg-gain/5" : "border-warm-white/10 bg-midnight"}`}>
        <span className={eligible ? "text-gain" : "text-muted-grey"}>
          ● {eligible ? "AUTO-ACCRUAL ACTIVE" : "BELOW ELIGIBILITY THRESHOLD"}
        </span>
        <span className="text-muted-grey tabular">
          ELIGIBILITY ≥ {minShare != null ? fmtUnits(minShare, 18, 5) : "10,000"} $ASS
          <span className="ml-4">YOUR SHARE: {share != null ? fmtUnits(share) : "—"}</span>
        </span>
      </div>

      {/* summary */}
      <div className="mt-6 grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-warm-white/10 bg-warm-white/10 md:grid-cols-3">
        {[
          { label: "AUTO-ACCRUED BASKET VALUE", value: basketUsd == null ? "—" : usd(basketUsd) },
          { label: "$ASS POSITION", value: assBal != null ? fmtUnits(assBal) : "—" },
          { label: "WALLET", value: shortAddr(address) },
        ].map((k) => (
          <div key={k.label} className="bg-midnight px-5 py-4">
            <div className="text-[11px] tracking-widest text-muted-grey">{k.label}</div>
            <div className="mt-1.5 font-mono text-2xl text-warm-white tabular">{k.value}</div>
          </div>
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[60fr_40fr]">
        {/* holdings */}
        <div className="rounded-xl border border-warm-white/10 bg-midnight p-5">
          <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">YOUR ASIAN bSTOCKS</h2>
          <table className="mt-3 w-full font-mono text-sm tabular">
            <thead>
              <tr className="text-left text-[11px] tracking-widest text-muted-grey">
                <th className="py-2 font-normal">ASSET</th>
                <th className="py-2 text-right font-normal">PRICE</th>
                <th className="py-2 text-right font-normal">24H</th>
                <th className="py-2 text-right font-normal">HOLDINGS</th>
                <th className="py-2 text-right font-normal">VALUE</th>
              </tr>
            </thead>
            <tbody>
              {STOCKS.map((s, i) => {
                const m = markets?.stocks[s.symbol];
                const b = stockBals[i];
                const v = b != null && m?.priceUsd != null
                  ? Number(formatBStockAmount(b).replace(/,/g, "")) * m.priceUsd : null;
                return (
                  <tr key={s.symbol} className="border-t border-warm-white/5">
                    <td className="py-3"><span className="text-warm-white">{s.symbol}</span>
                      <span className="ml-2 hidden text-xs text-muted-grey md:inline">{s.name}</span></td>
                    <td className="py-3 text-right text-warm-white/85">{usd(m?.priceUsd ?? null)}</td>
                    <td className={`py-3 text-right ${m?.change24h == null ? "text-muted-grey" : m.change24h >= 0 ? "text-gain" : "text-loss"}`}>
                      {m?.change24h == null ? "—" : pct(m.change24h)}</td>
                    <td className="py-3 text-right text-warm-white/85">{b != null ? formatBStockAmount(b) : "—"}</td>
                    <td className="py-3 text-right text-warm-white/85">{v == null ? "—" : usd(v)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {card && card.accruedRaw.some((a) => a > 0n) && (
            <p className="mt-3 font-mono text-xs text-muted-grey">
              PENDING DUST (auto-flushes when above payout minimum):{" "}
              {STOCKS.map((s, i) => card.accruedRaw[i] > 0n ? `${s.symbol} ${formatBStockAmount(card.accruedRaw[i])}` : null)
                .filter(Boolean).join(" · ")}
            </p>
          )}
        </div>

        {/* accrual activity */}
        <div className="rounded-md border border-term-border bg-term-bg p-5">
          <h2 className="font-mono text-xs tracking-[0.25em] text-term-dim">ACCRUAL ACTIVITY</h2>
          <div className="mt-3 space-y-1.5 font-mono text-[13px] tabular">
            {hist?.paid?.length ? hist.paid.slice(0, 14).map((p) => {
              const s = stockBy(p.asset);
              return (
                <a key={p.tx + p.asset + p.ts} href={`https://bscscan.com/tx/${p.tx}`} target="_blank" rel="noreferrer"
                  className="flex items-center justify-between rounded px-2 py-1.5 transition-colors hover:bg-warm-white/5">
                  <span className="text-term-dim">{new Date(p.ts * 1000).toISOString().slice(5, 16).replace("T", " ")}</span>
                  <span className="text-lavender">ACCRUED</span>
                  <span className="text-warm-white">{s?.symbol ?? shortAddr(p.asset)}</span>
                  <span className="text-gain">+{formatBStockAmount(BigInt(p.amount))}</span>
                </a>
              );
            }) : (
              <div className="py-8 text-center text-xs tracking-widest text-term-dim">
                NO ACCRUAL EVENTS FOR THIS WALLET YET
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}