"use client";
import Image from "next/image";
import { STOCKS, fmtUnits, formatBStockAmount, shortAddr } from "@/lib/ass";
import { useProtocolStats, useAssetCards, useMarkets, useIndexerProtocol, useExecutionFeed, usd, pct } from "@/lib/hooks";
import { AreaChart, Area, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from "recharts";

const stockBy = (addr: string) => STOCKS.find((s) => s.address.toLowerCase() === addr.toLowerCase());

export default function MarketDesk() {
  const { data: stats } = useProtocolStats();
  const { data: cards } = useAssetCards();
  const { data: markets } = useMarkets();
  const { data: idx } = useIndexerProtocol();
  const { data: feed } = useExecutionFeed();

  const accruedUsd = (() => {
    if (!cards || !markets) return null;
    let sum = 0;
    for (const s of STOCKS) {
      const c = cards.find((x) => x.asset.toLowerCase() === s.address.toLowerCase());
      const p = markets.stocks[s.symbol]?.priceUsd;
      if (!c || p == null) return null;
      sum += Number(formatBStockAmount(c.cumulativeDistributedRaw).replace(/,/g, "")) * p;
    }
    return sum;
  })();

  const history = idx?.history ?? [];
  const chart = history.length
    ? [{ day: "LAUNCH", bnb: 0 }, ...history.map((h) => ({ day: h.day.slice(5), bnb: Number(h.cum) / 1e18 }))]
    : [];
  const totalW = cards?.reduce((a, c) => a + c.weightBps, 0) ?? 0;

  const kpis = [
    { label: "bSTOCKS ACCRUED", value: accruedUsd == null ? "—" : usd(accruedUsd) },
    { label: "BNB PROCESSED", value: stats ? fmtUnits(stats.cumulativeBnbProcessed) : "—" },
    { label: "HOLDERS", value: idx ? String(idx.holders) : "—" },
    { label: "$ASS 24H VOLUME", value: usd(markets?.ass.volume24h ?? null, 0) },
  ];

  return (
    <div className="mx-auto max-w-7xl px-4 py-10">
      <h1 className="font-display text-4xl font-bold tracking-tight text-cream">ASIA DESK</h1>

      {/* KPIs */}
      <div className="mt-6 grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-warm-white/10 bg-warm-white/10 md:grid-cols-4">
        {kpis.map((k) => (
          <div key={k.label} className="bg-midnight px-5 py-4">
            <div className="text-[11px] tracking-widest text-muted-grey">{k.label}</div>
            <div className="mt-1.5 font-mono text-2xl text-warm-white tabular">{k.value}</div>
          </div>
        ))}
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[62fr_38fr]">
        {/* chart */}
        {/* chart */}
        <div className="flex flex-col rounded-xl border border-warm-white/10 bg-midnight p-10">
          <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">BNB PROCESSED OVER TIME</h2>
          <div className="mt-6 h-80 min-h-0 flex-1">
            {chart.length ? (
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={chart} margin={{ top: 8, right: 24, bottom: 8, left:24 }}>
                  <defs>
                    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
                      <stop offset="0%" stopColor="#9747FF" stopOpacity={0.35} />
                      <stop offset="100%" stopColor="#9747FF" stopOpacity={0} />
                    </linearGradient>
                  </defs>
                  <CartesianGrid stroke="rgba(245,241,232,0.06)" vertical={false} />
                  <XAxis dataKey="day" stroke="#A9A2B8" fontSize={11} tickLine={false}
                    axisLine={{ stroke: "rgba(245,241,232,0.1)" }} tickMargin={12} dy={4}
                    style={{ fontFamily: "var(--font-mono)" }}
                    label={{ value: "DATE (UTC)", position: "insideBottom", offset: -8,
                      fill: "#A9A2B8", fontSize: 10, letterSpacing: "0.2em" }} />
                  <YAxis stroke="#A9A2B8" fontSize={11} tickLine={false}
                    axisLine={{ stroke: "rgba(245,241,232,0.1)" }} width={64} tickMargin={8}
                    tickCount={7} domain={[0, (max: number) => max * 1.15]}
                    tickFormatter={(v) => v.toFixed(3)}
                    style={{ fontFamily: "var(--font-mono)" }}
                    label={{ value: "CUMULATIVE BNB", angle: -90, position: "insideLeft",
                      offset: -12, fill: "#A9A2B8", fontSize: 10, letterSpacing: "0.2em" }} />
                  <Tooltip contentStyle={{ background: "#0B0D18", border: "1px solid rgba(245,241,232,0.1)",
                      borderRadius: 6, fontFamily: "var(--font-mono)", fontSize: 12 }}
                    labelStyle={{ color: "#A9A2B8", marginBottom: 4 }}
                    formatter={(v) => [`${Number(v ?? 0).toFixed(6)} BNB`, "CUMULATIVE"]} />
                  <Area type="stepAfter" dataKey="bnb" stroke="#9747FF" strokeWidth={2} fill="url(#g)" />
                </AreaChart>
              </ResponsiveContainer>
            ) : (
              <div className="flex h-full items-center justify-center font-mono text-xs tracking-widest text-term-dim">
                AWAITING INDEXER DATA
              </div>
            )}
          </div>
        </div>

        {/* allocation — data-driven, never hardcoded */}
        <div className="rounded-xl border border-warm-white/10 bg-midnight p-5">
          <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">BASKET ALLOCATION</h2>
          <div className="mt-5 space-y-4">
            {STOCKS.map((s) => {
              const c = cards?.find((x) => x.asset.toLowerCase() === s.address.toLowerCase());
              const w = c && totalW ? (c.weightBps / totalW) * 100 : null;
              return (
                <div key={s.symbol}>
                  <div className="flex justify-between font-mono text-sm tabular">
                    <span className="text-warm-white">{s.symbol}</span>
                    <span className="text-muted-grey">{w == null ? "—" : `${w.toFixed(2)}%`}</span>
                  </div>
                  <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-warm-white/5">
                    <div className="h-full rounded-full bg-ass-purple transition-all duration-700" style={{ width: `${w ?? 0}%` }} />
                  </div>
                </div>
              );
            })}
          </div>
          {/* IMAGE: Strategist Terminal panel — rear/over-shoulder character at
              terminal, per spec. Drop at /public/brand/strategist-terminal.png */}
          <div className="relative mt-6 h-56 overflow-hidden rounded-lg border border-warm-white/10">
            <Image src="/brand/strategist-terminal.png" alt="Strategy Desk" fill className="object-cover" />
            <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-ass-black/90 to-transparent p-3">
              <p className="font-mono text-[11px] tracking-widest text-term-dim">STRATEGY DESK <span className="text-gain">● ACTIVE</span></p>
              <p className="mt-0.5 text-sm text-warm-white/85">We don&rsquo;t predict markets. We structure advantage.</p>
            </div>
          </div>
        </div>
      </div>

      <div className="mt-6 grid gap-6 lg:grid-cols-[55fr_45fr]">
        {/* basket holdings */}
        <div className="rounded-xl border border-warm-white/10 bg-midnight p-5">
          <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">BASKET</h2>
          <table className="mt-3 w-full font-mono text-sm tabular">
            <thead>
              <tr className="text-left text-[11px] tracking-widest text-muted-grey">
                <th className="py-2 font-normal">ASSET</th>
                <th className="py-2 text-right font-normal">PRICE</th>
                <th className="py-2 text-right font-normal">24H</th>
                <th className="py-2 text-right font-normal">ACQUIRED</th>
                <th className="py-2 text-right font-normal">ACCRUED</th>
              </tr>
            </thead>
            <tbody>
              {STOCKS.map((s) => {
                const c = cards?.find((x) => x.asset.toLowerCase() === s.address.toLowerCase());
                const m = markets?.stocks[s.symbol];
                return (
                  <tr key={s.symbol} className="border-t border-warm-white/5">
                    <td className="py-2.5">
                      <span className="text-warm-white">{s.symbol}</span>
                      <span className="ml-2 hidden text-xs text-muted-grey md:inline">{s.name}</span>
                    </td>
                    <td className="py-2.5 text-right text-warm-white/85">{usd(m?.priceUsd ?? null)}</td>
                    <td className={`py-2.5 text-right ${m?.change24h == null ? "text-muted-grey" : m.change24h >= 0 ? "text-gain" : "text-loss"}`}>
                      {m?.change24h == null ? "—" : pct(m.change24h)}
                    </td>
                    <td className="py-2.5 text-right text-warm-white/85">{c ? formatBStockAmount(c.cumulativeBoughtRaw) : "—"}</td>
                    <td className="py-2.5 text-right text-warm-white/85">{c ? formatBStockAmount(c.cumulativeDistributedRaw) : "—"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {/* execution feed */}
        <div className="rounded-md border border-term-border bg-term-bg p-5">
          <h2 className="font-mono text-xs tracking-[0.25em] text-term-dim"><strong>$ASS</strong> EXECUTION FEED</h2>
          <div className="mt-3 space-y-1.5 font-mono text-[13px] tabular">
            {feed?.length ? feed.slice(0, 12).map((f) => {
              const s = stockBy(f.asset);
              return (
                <a key={f.tx + f.asset} href={`https://bscscan.com/tx/${f.tx}`} target="_blank" rel="noreferrer"
                  className="flex items-center justify-between rounded px-2 py-1.5 transition-colors hover:bg-warm-white/5">
                  <span className="text-term-dim">{new Date(f.ts * 1000).toISOString().slice(5, 16).replace("T", " ")}</span>
                  <span className="text-gain">{f.action}</span>
                  <span className="text-warm-white">{s?.symbol ?? shortAddr(f.asset)}</span>
                  <span className="text-warm-white/70">{fmtUnits(BigInt(f.wbnbSpent))} BNB</span>
                  <span className="text-lavender">{shortAddr(f.tx)}</span>
                </a>
              );
            }) : (
              <div className="py-8 text-center text-xs tracking-widest text-term-dim">NO EXECUTIONS INDEXED YET</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}