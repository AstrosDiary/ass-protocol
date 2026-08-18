"use client";
import Image from "next/image";
import Link from "next/link";
import { STOCKS, ADDR, fmtUnits, formatBStockAmount } from "@/lib/ass";
import { useProtocolStats, useAssetCards, useMarkets, usd, pct } from "@/lib/hooks";
import { WhyAss } from "@/components/WhyAss";
import { Download } from "lucide-react";

const GALLERY = [
  { src: "/brand/gallery1.png", caption: "Markets sleep. Strategy doesn't." },
  { src: "/brand/my-desk.png", caption: "Discipline. Patience. Conviction." },
  { src: "/brand/asia-desk.png", caption: "Long-term edge. Asian exposure." },
  { src: "/brand/gallery2.png", caption: "Asia uponly." },
  { src: "/brand/gallery3.png", caption: "Welcome to The Strategy." },
  { src: "/brand/gallery4.png", caption: "ASS always works." },
  { src: "/brand/gallery5.png", caption: "Rate my ASS bag?" },
  { src: "/brand/gallery6.png", caption: "Penthouse views only." },
];

export default function Home() {
  const { data: stats } = useProtocolStats();
  const { data: cards } = useAssetCards();
  const { data: markets } = useMarkets();

  // BSTOCKS ACCRUED (USD): Σ cumulativeDistributedRaw × live price — real math or dash
  const accruedUsd = (() => {
    if (!cards || !markets) return null;
    let sum = 0;
    for (const s of STOCKS) {
      const card = cards.find((c) => c.asset.toLowerCase() === s.address.toLowerCase());
      const p = markets.stocks[s.symbol]?.priceUsd;
      if (!card || p == null) return null;
      sum += Number(formatBStockAmount(card.cumulativeDistributedRaw).replace(/,/g, "")) * p;
    }
    return sum;
  })();

  return (
    <>
      {/* ============ HERO ============ */}
      <section className="relative aspect-[9/16] max-h-[780px] w-full overflow-hidden md:aspect-video md:max-h-none md:min-h-[560px]">
        <div className="absolute inset-0">
          <Image src="/brand/hero-mobile.png" alt="" fill priority
            className="object-cover md:hidden" />
          <Image src="/brand/hero.png" alt="" fill priority
            className="hidden object-cover md:block" />
          <div className="absolute inset-0 bg-gradient-to-r from-ass-black via-ass-black/30 to-transparent" />
          <div className="absolute inset-0 bg-gradient-to-t from-ass-black via-transparent to-ass-black/30" />
        </div>
        <div className="relative mx-auto flex h-full max-w-7xl flex-col justify-center px-4">
          <h1 className="font-display text-4xl font-bold tracking-tight text-cream [-webkit-text-stroke:1px_#FFF1D8] md:[-webkit-text-stroke:2.5px_#FFF1D8] md:text-7xl">
            <span className="text-5xl md:text-8xl">A</span>SIAN <span className="text-5xl md:text-8xl">S</span>TOCK <span className="text-5xl md:text-8xl">S</span>TRATEGY
          </h1>
          <p className="mt-2 font-display text-4xl font-bold text-ass-purple [-webkit-text-stroke:1.5px_#9747FF] md:[-webkit-text-stroke:3px_#9747FF] md:text-7xl">$ASS</p>
          <p className="mt-6 font-display text-sm tracking-[0.2em] text-lavender">
            THE ASIAN bSTOCK PROTOCOL.
          </p>
          <p className="mt-3 max-w-md text-warm-white/85">
            Hold <strong>$ASS</strong> and automatically accrue Asian <strong>bStocks</strong> in your wallet.
            Passive Exposure. Real Asian Markets. Real ASS.
          </p>
          <div className="mt-8 flex gap-3">
            <a href={`https://flap.sh/bnb/${ADDR.token}`} target="_blank" rel="noreferrer"
              className="rounded-lg bg-deep-purple px-6 py-3 font-display font-bold text-cream transition-colors hover:bg-ass-purple">
              BUY $ASS
            </a>
            <Link href="/market-desk"
              className="rounded-lg border border-warm-white/15 bg-deep-navy/80 px-6 py-3 font-display font-bold text-warm-white transition-colors hover:border-lavender/50">
              VIEW ASIA DESK
            </Link>
          </div>

          {/* compact protocol card — real sources only */}
          <div className="mt-12 grid max-w-2xl grid-cols-2 gap-px overflow-hidden rounded-xl border border-warm-white/10 bg-warm-white/10 md:grid-cols-4">
            {[
              { label: "$ASS PRICE", value: usd(markets?.ass.priceUsd ?? null, 6) },
              { label: "24H VOLUME", value: usd(markets?.ass.volume24h ?? null, 0) },
              { label: "bSTOCKS ACQUIRED", value: accruedUsd == null ? "—" : usd(accruedUsd) },
              { label: "BNB PROCESSED", value: stats ? fmtUnits(stats.cumulativeBnbProcessed) : "—" },
            ].map((s) => (
              <div key={s.label} className="bg-midnight px-4 py-3">
                <div className="text-[11px] tracking-widest text-muted-grey">{s.label}</div>
                <div className="mt-1 font-mono text-lg text-warm-white tabular">{s.value}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ============ WHY $ASS ============ */}
      <WhyAss />

      {/* ============ HOW IT WORKS ============ */}
      <section className="mx-auto max-w-7xl px-4 ">
        <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">| HOW IT WORKS</h2>
        <div className="mt-4 grid gap-4 md:grid-cols-3">
          {[
            ["1", "BUY $ASS", "Trade $ASS on the open market. Every trade drives the strategy."],
            ["2", "PROTOCOL BUYS ASIA", "Trading tax automatically converts into the Asian bStocks basket."],
            ["3", "ACCRUE AUTOMATICALLY", "Asian bStocks are automatically accrued in your wallet. No actions."],
          ].map(([n, t, d]) => (
            <div key={n} className="rounded-xl border border-warm-white/10 bg-midnight p-6">
              <span className="font-display text-4xl font-bold text-ass-purple">{n}</span>
              <h3 className="mt-3 font-display text-cream">{t}</h3>
              <p className="mt-2 text-sm text-muted-grey">{d}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ============ BASKET ============ */}
      <section className="mx-auto max-w-7xl px-4 pb-16 py-8">
        <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">| ASIA bSTOCKS BASKET</h2>
        <div className="mt-4 grid gap-4 md:grid-cols-3">
          {STOCKS.map((s) => {
            const m = markets?.stocks[s.symbol];
            return (
              <div key={s.symbol} className="rounded-md border border-term-border bg-term-bg p-5">
                <div className="flex items-baseline justify-between">
                  <h3 className="font-mono text-lg text-warm-white">{s.symbol}</h3>
                  <span className="text-[11px] tracking-widest text-term-dim">{s.region.toUpperCase()}</span>
                </div>
                <p className="text-sm text-muted-grey">{s.name}</p>
                <div className="mt-4 flex items-baseline gap-2 font-mono tabular">
                  <span className="text-xl text-warm-white">{usd(m?.priceUsd ?? null)}</span>
                  {m?.change24h != null && (
                    <span className={m.change24h >= 0 ? "text-gain" : "text-loss"}>{pct(m.change24h)} <span className="text-[11px] text-sm">(24h)</span></span>
                  )}
                </div>
                <p className="mt-3 flex items-center gap-1.5 text-[11px] text-term-dim">
                  <span className="inline-block h-1.5 w-1.5 rounded-full bg-ass-purple" />
                  TOKENIZED ON BNB CHAIN
                </p>
              </div>
            );
          })}
        </div>
      </section>

      {/* ============ STRATEGY DESK GALLERY ============ */}
      <section id="gallery" className="mx-auto max-w-7xl px-4 py-12 pb-8">
        <h2 className="font-display text-xs tracking-[0.25em] text-muted-grey">| <strong>$ASS</strong> GALLERY</h2>
        <div className="mt-4 grid grid-cols-2 gap-4 md:grid-cols-4">
          {GALLERY.map((g) => (
            <figure key={g.src} className="group overflow-hidden rounded-xl border border-warm-white/10 bg-midnight">
              <div className="relative h-72 w-full">
                <Image src={g.src} alt={g.caption} fill className="object-cover" />
                <a
                  href={g.src}
                  download
                  aria-label={`Download: ${g.caption}`}
                  title="Download for socials"
                  className="absolute right-2 top-2 rounded-lg border border-warm-white/15 bg-ass-black/70 p-2 text-warm-white/80 opacity-0 backdrop-blur-sm transition-all duration-200 hover:border-lavender/50 hover:text-lavender focus-visible:opacity-100 group-hover:opacity-100 max-md:opacity-100"
                >
                  <Download size={16} strokeWidth={2} />
                </a>
              </div>
              <figcaption className="px-4 py-3 text-sm text-warm-white/85">{g.caption}</figcaption>
            </figure>
          ))}
        </div>
      </section>
    </>
  );
}
