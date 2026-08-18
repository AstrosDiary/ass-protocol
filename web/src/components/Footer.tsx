"use client";
import Image from "next/image";
import { useTranslations } from "next-intl";

export function Footer() {
  const t = useTranslations("footer");
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
            <span className="text-warm-white/50">{t("disclosureLabel")}</span>
            {t("disclosureBody")}
          </p>

          <p>{t("bstocksBody")}</p>

          <p>
            <span className="text-warm-white/50">{t("riskLabel")}</span>
            {t("riskBody")}
          </p>
        </div>

        {/* Footer bar */}
        <div className="mt-6 flex flex-col gap-3 border-t border-warm-white/10 py-4 pt-5 text-xs text-muted-grey sm:flex-row sm:items-center sm:justify-between">
          <span className="font-display tracking-widest">
            $ASS — ASIAN STOCK STRATEGY
          </span>
          <span>{t("rights")}</span>
        </div>
      </div>
    </footer>
  );
}
