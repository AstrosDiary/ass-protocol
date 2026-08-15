"use client";
import Link from "next/link";
import Image from "next/image";
import { usePathname } from "next/navigation";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { shortAddr, ADDR } from "@/lib/ass";

const NAV = [
  { href: "/", label: "HOME" },
  { href: "/market-desk", label: "MARKET DESK" },
  { href: "/my-desk", label: "MY DESK" },
  { href: "/docs", label: "DOCS" },
];

export function Header() {
  const path = usePathname();
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  return (
    <header className="sticky top-0 z-50 border-b border-warm-white/10 bg-ass-black/90 backdrop-blur-sm">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4">
        <Link href="/" className="flex items-center gap-2">
          <Image src="/brand/logo-nav.png" alt="$ASS" 
            width={72} height={40} priority
            className="h-12 w-auto object-contain" />
        </Link>
        <nav className="hidden gap-8 md:flex font-display text-sm tracking-widest">
          {NAV.map((n) => (
            <Link key={n.href} href={n.href}
              className={path === n.href
                ? "text-cream border-b-2 border-ass-purple pb-1"
                : "text-muted-grey hover:text-warm-white transition-colors pb-1"}>
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="flex items-center gap-3">
          <a href={`https://flap.sh/bnb/${ADDR.token}`} target="_blank" rel="noreferrer"
            className="rounded-lg bg-deep-purple px-4 py-2 font-display text-sm text-cream hover:bg-ass-purple transition-colors">
            BUY $ASS
          </a>
          {isConnected ? (
            <button onClick={() => disconnect()}
              className="rounded-lg border border-warm-white/15 bg-deep-navy px-4 py-2 font-mono text-sm text-warm-white tabular">
              {shortAddr(address!)}
            </button>
          ) : (
            <button onClick={() => connect({ connector: connectors[0] })}
              className="rounded-lg border border-warm-white/15 bg-deep-navy px-4 py-2 font-display text-sm text-warm-white hover:border-lavender/50 transition-colors">
              CONNECT WALLET
            </button>
          )}
        </div>
      </div>
    </header>
  );
}