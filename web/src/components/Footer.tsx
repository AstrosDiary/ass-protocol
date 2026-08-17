import Image from "next/image";

export function Footer() {
  return (
    <footer className="mt-24 border-t border-warm-white/10">
      <div className="mx-auto max-w-7xl px-4 py-16">
        {/* Risk / product disclosure */}
        <div className="max-w-5xl space-y-3 text-[10px] leading-relaxed text-muted-grey/50">
          <Image src="/brand/logo-nav.png" alt="$ASS" 
            width={72} height={40} priority
            className="h-12 w-auto object-contain opacity-50" 
          />
        
          <p>
            <span className="text-warm-white/50">$ASS Protocol Disclosure — </span>
            Asian Stock Strategy ($ASS) is a memecoin with a custom-built
            on-chain protocol that uses trading-tax revenue to acquire and
            automatically accrue supported bStocks to eligible $ASS holders on
            BNB Chain.
          </p>

          <p>
            bStocks are tokenized securities and are not direct shares or
            brokerage-held stock in the underlying companies. Holding bStocks
            does not make the holder a direct shareholder and does not provide
            direct voting, dividend, inspection or other shareholder rights.
            Corporate actions, including dividends, may instead be reflected
            through the bStocks Multiplier mechanism in accordance with the
            issuer&apos;s applicable terms. bStocks remain subject to their own
            issuer terms, eligibility requirements, market risks and
            jurisdictional restrictions.
          </p>

          <p>
            <span className="text-warm-white/50">Risk Notice — </span>
            $ASS is a speculative memecoin and participation involves
            significant risk. The protocol makes no promise or guarantee of
            profit, yield, appreciation or financial return. The value of $ASS,
            bStocks and other digital assets may fluctuate substantially and
            users may lose some or all of the value committed. Nothing on this
            website constitutes financial, investment, legal or tax advice, or
            a recommendation or solicitation to buy or sell any asset. Always
            conduct your own research and ensure participation is lawful in
            your jurisdiction.
          </p>
        </div>

        {/* Footer bar */}
        <div className="mt-6 py-4 flex flex-col gap-3 border-t border-warm-white/10 pt-5 text-xs text-muted-grey sm:flex-row sm:items-center sm:justify-between">
          <span className="font-display tracking-widest">
            $ASS — ASIAN STOCK STRATEGY
          </span>

          <span>© 2026 Asian Stock Strategy.</span>
        </div>
      </div>
    </footer>
  );
}