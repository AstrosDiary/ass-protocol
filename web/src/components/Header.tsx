"use client";
import Link from "next/link";
import Image from "next/image";
import { useEffect, useState } from "react";
import { usePathname } from "next/navigation";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { Menu, X } from "lucide-react";
import { shortAddr, ADDR } from "@/lib/ass";

const NAV = [
  { href: "/", label: "HOME" },
  { href: "/market-desk", label: "ASIA DESK" },
  { href: "/my-desk", label: "MY ASIAFOLIO" },
  { href: "/docs", label: "DOCS" },
];

export function Header() {
  const path = usePathname();
  const [mounted, setMounted] = useState(false);
  const [open, setOpen] = useState(false);
  useEffect(() => setMounted(true), []);
  useEffect(() => setOpen(false), [path]); // close menu on navigation
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  const wallet = mounted && isConnected ? (
    <button onClick={() => disconnect()}
      className="rounded-lg border border-warm-white/15 bg-deep-navy px-3 py-2 font-mono text-xs text-warm-white tabular md:px-4 md:text-sm">
      {shortAddr(address!)}
    </button>
  ) : (
    <button onClick={() => connect({ connector: connectors[0] })} suppressHydrationWarning
      className="rounded-lg border border-warm-white/15 bg-deep-navy px-3 py-2 font-display text-xs text-warm-white transition-colors hover:border-lavender/50 md:px-4 md:text-sm">
      CONNECT
    </button>
  );

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
          <a href={`https://flap.sh/bnb/${ADDR.token}`} target="_blank" rel="noreferrer"
            className="rounded-lg bg-deep-purple px-3 py-2 font-display text-xs text-cream transition-colors hover:bg-ass-purple md:px-4 md:text-sm">
            BUY $ASS
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
              className={`block rounded px-3 py-2.5 font-display text-sm tracking-widest ${
                path === n.href ? "bg-ass-purple/10 text-cream" : "text-muted-grey"}`}>
              {n.label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  );
}