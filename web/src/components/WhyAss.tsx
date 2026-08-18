"use client";
import { useEffect, useRef, useState } from "react";
import { ADDR } from "@/lib/ass";

const NODES = [
  { label: "TRADE", value: "$ASS", caption: "3% TAX",
    detail: "Every buy and sell feeds the strategy." },
  { label: "VAULT", value: "BNB", caption: "BNB RECEIVED",
    detail: "Trading tax accumulates as BNB." },
  { label: "BUY ASIA", value: "BABAB · TSMB · SKHYB", caption: "bSTOCKS ACQUIRED",
    detail: "BNB becomes Alibaba, TSMC and SK Hynix." },
  { label: "ACCRUE", value: "WALLET", caption: "AUTO-UPDATED",
    detail: "Eligible holders update automatically." },
];

const PROOFS = [
  { label: "BNB CHAIN", detail: "Launched on BNB Chain via flap.sh — liquidity locked by the launchpad." },
  { label: "AUTOMATIC", detail: "No staking, no claiming, no manual actions — the protocol runs itself." },
  { label: "15-MIN CYCLE", detail: "A recurring heartbeat converts accumulated tax into the basket." },
  { label: "ON-CHAIN VERIFIED", detail: "Vault, executor and distributor activity can be followed directly on BscScan." },
];

export function WhyAss() {
  const [active, setActive] = useState(0);
  const [frozen, setFrozen] = useState(false);
  const [proof, setProof] = useState<number | null>(null);
  const reduced = useRef(false);

  useEffect(() => {
    reduced.current = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced.current) return;
    const id = setInterval(() => {
      setActive((a) => (frozen ? a : (a + 1) % NODES.length));
    }, 2600);
    return () => clearInterval(id);
  }, [frozen]);

  return (
    <section className="mx-auto max-w-7xl px-4 py-18">
      {/* ============ thesis: headline + research stats ============ */}
      <div className="grid items-start gap-12 lg:grid-cols-[55fr_45fr]">
        <div>
          <p className="font-mono text-xs tracking-[0.25em] text-muted-grey">| WHY <strong>$ASS</strong></p>
          <h2 className="mt-4 font-display text-5xl font-bold leading-[0.98] tracking-tight md:text-6xl">
            <span className="text-cream">THE CHAIN IS BNB.</span><br />
            <span className="text-ass-purple">THE THESIS IS <span style={{ textDecoration: 'underline' }}>ASIA.</span></span>
          </h2>
          <p className="mt-6 max-w-lg text-lg leading-relaxed text-warm-white/85">
            APAC is crypto&rsquo;s fastest-growing region. Asia sits at the centre of
            global semiconductor manufacturing. $ASS turns BNB Chain trading
            activity into automatically accrued Alibaba, TSMC and SK Hynix bStocks.
          </p>
        </div>
        <div className="grid gap-8 sm:grid-cols-3 lg:pt-10">
          {[
            ["+69%", "APAC ON-CHAIN GROWTH", "2025 // CHAINALYSIS"],
            [">80%", "GLOBAL SEMICONDUCTORS MADE IN ASIA", "ADB"],
            ["3", "ASIAN bSTOCKS", "AUTO-ACCRUED BY $ASS"],
          ].map(([n, l, src]) => (
            <div key={l}>
              <div className="font-mono text-5xl text-cream tabular md:text-5xl">{n}</div>
              <div className="mt-2 text-[11px] font-medium leading-snug tracking-widest text-warm-white/70">{l}</div>
              <div className="mt-1 font-mono text-[10px] tracking-widest text-muted-grey">{src}</div>
            </div>
          ))}
        </div>
      </div>

      {/* ============ the engine — horizontal capital flow ============ */}
      <p className="mt-20 font-display text-2xl font-bold tracking-tight text-cream md:text-3xl">
        EVERY TRADE FUNDS ASIA.
      </p>
      <div className="mt-4 overflow-hidden rounded-md border border-term-border bg-term-bg">
        <div className="flex items-center justify-between border-b border-term-border px-4 py-2.5 font-mono text-sm">
          <span className="tracking-wider text-term-text">$ASS STRATEGY ENGINE</span>
          <span className="flex items-center gap-1.5 text-[11px] text-term-dim">
            <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-gain" /> LIVE
          </span>
        </div>

        <div className="px-4 py-8 md:px-8"
          onMouseLeave={() => setFrozen(false)}>
          {/* flow line + travelling pulse */}
          <div className="relative">
            <div className="absolute left-[12.5%] right-[12.5%] top-[9px] h-px bg-term-border" />
            <span className="flow-dot absolute left-[12.5%] top-[7px] h-[5px] w-[5px] rounded-full bg-ass-purple"
              style={{ "--flow-dist": "min(74vw, 900px)" } as React.CSSProperties} />
            <div className="relative grid grid-cols-4">
              {NODES.map((n, i) => {
                const on = i === active;
                return (
                  <button key={n.label} type="button"
                    onMouseEnter={() => { setActive(i); setFrozen(true); }}
                    onFocus={() => { setActive(i); setFrozen(true); }}
                    onClick={() => { setActive(i); setFrozen(true); }}
                    className="group flex flex-col items-center gap-2 outline-none">
                    <span className={`z-10 h-[19px] w-[19px] rounded-full border-2 transition-colors duration-300 ${
                      on ? "border-ass-purple bg-ass-purple/30" : "border-term-border bg-term-bg group-hover:border-lavender/50"}`} />
                    <span className={`font-display text-xs tracking-[0.2em] transition-colors duration-300 md:text-sm ${
                      on ? "text-cream" : "text-muted-grey"}`}>{n.label}</span>
                    <span className={`px-1 text-center font-mono text-[11px] tabular transition-colors duration-300 md:text-sm ${
                      on ? "text-warm-white" : "text-term-dim"}`}>{n.value}</span>
                    <span className={`font-mono text-[9px] tracking-widest transition-colors duration-300 md:text-[10px] ${
                      on ? "text-lavender" : "text-term-dim/60"}`}>{n.caption}</span>
                  </button>
                );
              })}
            </div>
          </div>
          {/* single explanation line for the active node */}
          <p className="mt-7 text-center font-mono text-sm text-warm-white/80" aria-live="polite">
            {NODES[active].detail}
          </p>
        </div>

        <div className="border-t border-term-border px-4 py-2 font-mono text-[11px] tracking-widest text-term-dim">
          EVERY CYCLE BUYS ASIA.
        </div>
      </div>

      {/* ============ proof strip ============ */}
      <div className="mt-8">
        <div className="flex flex-wrap items-center gap-x-8 gap-y-3"
          onMouseLeave={() => setProof(null)}>
          {PROOFS.map((p, i) => (
            <button key={p.label} type="button"
              onMouseEnter={() => setProof(i)} onFocus={() => setProof(i)} onClick={() => setProof(i)}
              className={`flex items-center gap-2 font-mono text-xs tracking-widest transition-colors ${
                proof === i ? "text-warm-white" : "text-muted-grey hover:text-warm-white/80"}`}>
              <span className={`h-1.5 w-1.5 rounded-full ${proof === i ? "bg-ass-purple" : "bg-lavender/40"}`} />
              {p.label}
            </button>
          ))}
          <a href={`https://bscscan.com/address/${ADDR.distributor}`} target="_blank" rel="noreferrer"
            className="font-mono text-xs tracking-widest text-lavender transition-colors hover:text-violet">
            VIEW CONTRACTS ↗
          </a>
        </div>
        <p className={`mt-3 min-h-5 font-mono text-sm text-warm-white/70 transition-opacity duration-300 ${
          proof === null ? "opacity-0" : "opacity-100"}`} aria-live="polite">
          {proof === null ? "" : PROOFS[proof].detail}
        </p>
      </div>

    </section>
  );
}