"use client";
import Image from "next/image";
import { useEffect, useState } from "react";
import { Link, usePathname } from "@/i18n/routing";
import { useTranslations, useLocale } from "next-intl";
import { useAccount, useConnect, useDisconnect, useChainId } from "wagmi";
import { Menu, X } from "lucide-react";
import { shortAddr, ADDR } from "@/lib/ass";
import { useAppKit } from "@reown/appkit/react";
import { HAS_APPKIT } from "@/lib/wagmi";

export function Header() {
  const path = usePathname(); // locale-stripped: "/market-desk" even on /zh/market-desk
  const t = useTranslations("nav");
  const locale = useLocale();
  const [mounted, setMounted] = useState(false);
  const [open, setOpen] = useState(false);
  useEffect(() => setMounted(true), []);
  useEffect(() => setOpen(false), [path]); // close menu on navigation

  const NAV = [
    { href: "/", label: t("home") },
    { href: "/market-desk", label: t("asiaDesk") },
    { href: "/my-desk", label: t("myAsiafolio") },
    { href: "/docs", label: t("docs") },
  ];

  const wallet = <WalletControl mounted={mounted} />;

  return (
    <header className="sticky top-0 z-50 border-b border-warm-white/10 bg-ass-black/90 backdrop-blur-sm">
      <div className="mx-auto flex h-14 max-w-7xl items-center justify-between gap-2 px-4 md:h-16">
        <Link href="/" className="flex shrink-0 items-center">
          <Image src="/brand/logo-nav.png" alt="$ASS — Asian Stock Strategy"
            width={1146} height={476} priority className="h-8 w-auto object-contain md:h-12" />
        </Link>
        <nav className="hidden gap-8 font-display text-sm tracking-widest md:flex">
          {NAV.map((n) => (
            <Link key={n.href} href={n.href}
              className={path === n.href
                ? "border-b-2 border-ass-purple pb-1 text-cream"
                : "pb-1 text-muted-grey transition-colors hover:text-warm-white"}>
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="flex items-center gap-2">
          <Link href={path} locale={locale === "en" ? "zh" : "en"}
            className="whitespace-nowrap rounded-lg border border-lavender/50 px-2.5 py-1.5 font-mono text-[11px] text-warm-white/80 transition-colors md:px-3 md:py-2 md:text-xs">
            {locale === "en" ? "中文" : "EN"}
          </Link>
          <a href={`https://flap.sh/bnb/${ADDR.token}`} target="_blank" rel="noreferrer"
            className="whitespace-nowrap rounded-lg bg-deep-purple px-2.5 py-1.5 font-display text-[11px] text-cream transition-colors hover:bg-ass-purple md:px-4 md:py-2 md:text-sm">
            {t("buy")}
          </a>
          {wallet}
          <button onClick={() => setOpen(!open)} aria-label="Menu"
            className="rounded-lg border border-warm-white/15 p-2 text-warm-white md:hidden">
            {open ? <X size={18} /> : <Menu size={18} />}
          </button>
        </div>
      </div>
      {/* mobile menu */}
      {open && (
        <nav className="border-t border-warm-white/10 bg-ass-black px-4 py-3 md:hidden">
          {NAV.map((n) => (
            <Link key={n.href} href={n.href}
              className={`block rounded px-3 py-2.5 font-display text-s tracking-widest ${
                path === n.href ? "bg-ass-purple/10 text-cream" : "text-muted-grey"}`}>
              {n.label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  );
}

function WalletControl({ mounted }: { mounted: boolean }) {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const t = useTranslations("nav");

  const chip = "whitespace-nowrap rounded-lg border border-warm-white/15 bg-deep-navy px-2.5 py-1.5 font-mono text-[11px] text-warm-white tabular md:px-4 md:py-2 md:text-sm";
  const btn = "whitespace-nowrap rounded-lg border border-warm-white/15 bg-deep-navy px-2.5 py-1.5 font-display text-[11px] text-warm-white transition-colors hover:border-lavender/50 md:px-4 md:py-2 md:text-sm";

  if (!HAS_APPKIT) {
    return mounted && isConnected ? (
      <button onClick={() => disconnect()} className={chip}>{shortAddr(address!)}</button>
    ) : (
      <button onClick={() => connect({ connector: connectors[0] })} suppressHydrationWarning className={btn}>{t("connect")}</button>
    );
  }
  return <AppKitWallet mounted={mounted} chip={chip} btn={btn} />;
}

function AppKitWallet({ mounted, chip, btn }: { mounted: boolean; chip: string; btn: string }) {
  const { open } = useAppKit();
  const { address, isConnected } = useAccount();
  const t = useTranslations("nav");
  const chainId = useChainId();
  const wrongNet = isConnected && chainId !== 56;

  return mounted && isConnected ? (
    <button
      onClick={() => open({ view: wrongNet ? "Networks" : "Account" })}
      className={
        wrongNet
          ? "cursor-pointer whitespace-nowrap rounded-lg border border-loss/40 bg-loss/10 px-2.5 py-1.5 font-mono text-[11px] text-loss md:px-4 md:py-2 md:text-sm"
          : `cursor-pointer ${chip}`
      }
    >
      {wrongNet ? "WRONG NETWORK" : shortAddr(address!)}
    </button>
  ) : (
    <button onClick={() => open()} suppressHydrationWarning className={`cursor-pointer ${btn}`}>
      {t("connect")}
    </button>
  );
}
