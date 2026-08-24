"use client";
import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { ADDR } from "@/lib/ass";

export function WhyAss() {
  const t = useTranslations("why");
  const [active, setActive] = useState(0);
  const [frozen, setFrozen] = useState(false);
  const [proof, setProof] = useState<number | null>(null);
  const reduced = useRef(false);

  const NODES = [
    { label: t("n1Label"), value: "$ASS", caption: "3% TAX", detail: t("n1Detail") },
    { label: t("n2Label"), value: "BNB", caption: "BNB RECEIVED", detail: t("n2Detail") },
    { label: t("n3Label"), value: "BABAB · TSMB · SKHYB", caption: "bSTOCKS ACQUIRED", detail: t("n3Detail") },
    { label: t("n4Label"), value: t("n4Value"), caption: "AUTO-UPDATED", detail: t("n4Detail") },
  ];
  const PROOFS = [
    { label: "BNB CHAIN", detail: t("p1Detail") },
    { label: t("p2Label"), detail: t("p2Detail") },
    { label: t("p3Label"), detail: t("p3Detail") },
    { label: t("p4Label"), detail: t("p4Detail") },
  ];

  useEffect(() => {
    reduced.current = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced.current) return;
    const id = setInterval(() => {
      setActive((a) => (frozen ? a : (a + 1) % 4));
    }, 2600);
    return () => clearInterval(id);
  }, [frozen]);

  return (
    <section className="mx-auto max-w-7xl px-4 py-18">
      <div className="grid items-start gap-12 lg:grid-cols-[55fr_45fr]">
        <div>
          <p className="font-mono text-xs tracking-[0.25em] text-muted-grey">| {t("eyebrow")} <strong>$ASS</strong></p>
          <h2 className="mt-4 font-display text-5xl font-bold leading-[0.98] tracking-tight md:text-6xl">
            <span className="text-cream">{t("headline1")}</span><br />
            <span className="text-ass-purple">{t("headline2")} <span style={{ textDecoration: "underline" }}>{t("headline2u")}</span></span>
          </h2>
          <p className="mt-6 max-w-lg text-lg leading-relaxed text-warm-white/85">{t("intro")}</p>
        </div>
        <div className="grid gap-8 sm:grid-cols-3 lg:pt-10">
          {[
            ["+69%", t("stat1Label"), "2025 // CHAINALYSIS"],
            [">80%", t("stat2Label"), "ADB"],
            ["3", t("stat3Label"), t("stat3Src")],
          ].map(([n, l, src]) => (
            <div key={l}>
              <div className="font-mono text-5xl text-cream tabular">{n}</div>
              <div className="mt-2 text-[11px] font-medium leading-snug tracking-widest text-warm-white/70">{l}</div>
              <div className="mt-1 font-mono text-[10px] tracking-widest text-muted-grey">{src}</div>
            </div>
          ))}
        </div>
      </div>

      <p className="mt-20 font-display text-2xl font-bold tracking-tight text-cream md:text-3xl">{t("engineHeadline")}</p>
      <div className="mt-4 overflow-hidden rounded-md border border-term-border bg-term-bg">
        <div className="flex items-center justify-between border-b border-term-border px-4 py-2.5 font-mono text-sm">
          <span className="tracking-wider text-term-text">$ASS STRATEGY ENGINE</span>
          <span className="flex items-center gap-1.5 text-[11px] text-term-dim">
            <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-gain" /> LIVE
          </span>
        </div>

        <div className="px-4 py-8 md:px-8" onMouseLeave={() => setFrozen(false)}>
          <div className="relative">
            <div className="absolute left-[12.5%] right-[12.5%] top-[9px] h-px bg-term-border" />
            <span className="flow-dot absolute left-[12.5%] top-[7px] h-[5px] w-[5px] rounded-full bg-ass-purple"
              style={{ "--flow-dist": "min(74vw, 900px)" } as React.CSSProperties} />
            <div className="relative grid grid-cols-4">
              {NODES.map((n, i) => {
                const on = i === active;
                return (
                  <button key={i} type="button"
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
          <p className="mt-7 text-center font-mono text-sm text-warm-white/80" aria-live="polite">
            {NODES[active].detail}
          </p>
        </div>

        <div className="border-t border-term-border px-4 py-2 font-mono text-[11px] tracking-widest text-term-dim">
          {t("engineFooter")}
        </div>
      </div>

      <div className="mt-8">
        <div className="flex flex-wrap items-center gap-x-8 gap-y-3" onMouseLeave={() => setProof(null)}>
          {PROOFS.map((p, i) => (
            <button key={i} type="button"
              onMouseEnter={() => setProof(i)} onFocus={() => setProof(i)} onClick={() => setProof(i)}
              className={`flex items-center gap-2 font-mono text-xs tracking-widest transition-colors ${
                proof === i ? "text-warm-white" : "text-muted-grey hover:text-warm-white/80"}`}>
              <span className={`h-1.5 w-1.5 rounded-full ${proof === i ? "bg-ass-purple" : "bg-lavender/40"}`} />
              {p.label}
            </button>
          ))}
          <a href={`https://bscscan.com/address/${ADDR.basket}`} target="_blank" rel="noreferrer"
            className="font-mono text-xs tracking-widest text-lavender transition-colors hover:text-violet">
            {t("viewContracts")} ↗
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
