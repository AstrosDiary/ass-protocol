"use client";
import { STOCKS } from "@/lib/ass";
import { useMarkets, usd, pct } from "@/lib/hooks";

export function LiveTicker() {
  const { data } = useMarkets();
  const items = [
    { label: "$ASS", m: data?.ass },
    ...STOCKS.map((s) => ({ label: s.symbol, m: data?.stocks[s.symbol] })),
  ];
  return (
    <div className="border-b border-term-border bg-term-bg">
      <div className="mx-auto flex max-w-7xl items-center gap-6 overflow-x-auto px-4 py-1.5 font-mono text-xs tabular">
        <span className="flex items-center gap-1.5 whitespace-nowrap text-term-dim">
          <span className="inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-ass-purple" />
          LIVE MARKETS
        </span>
        {items.map(({ label, m }) => (
          <span key={label} className="whitespace-nowrap text-term-text/90">
            {label} <span className="text-warm-white/70">{usd(m?.priceUsd ?? null)}</span>
            {m?.change24h != null && (
              <span className={m.change24h >= 0 ? "text-gain" : "text-loss"}> {pct(m.change24h)}</span>
            )}
          </span>
        ))}
      </div>
    </div>
  );
}