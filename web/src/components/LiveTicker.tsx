"use client";
import { STOCKS } from "@/lib/ass";

/** Slim terminal strip. Prices wired to the data layer next pass —
 * placeholders render as "—", never invented numbers (spec rule). */
export function LiveTicker() {
  const items = [
    { label: "$ASS", value: "—", change: null as number | null },
    ...STOCKS.map((s) => ({ label: s.symbol, value: "—", change: null as number | null })),
  ];
  return (
    <div className="border-b border-term-border bg-term-bg">
      <div className="mx-auto flex max-w-7xl items-center gap-6 overflow-x-auto px-4 py-1.5 font-mono text-xs tabular">
        <span className="flex items-center gap-1.5 whitespace-nowrap text-term-dim">
          <span className="inline-block h-1.5 w-1.5 rounded-full bg-ass-purple animate-pulse" />
          LIVE MARKETS
        </span>
        {items.map((i) => (
          <span key={i.label} className="whitespace-nowrap text-term-text/90">
            {i.label} <span className="text-warm-white/70">{i.value}</span>
            {i.change !== null && (
              <span className={i.change >= 0 ? "text-gain" : "text-loss"}>
                {" "}{i.change >= 0 ? "+" : ""}{i.change}%
              </span>
            )}
          </span>
        ))}
      </div>
    </div>
  );
}