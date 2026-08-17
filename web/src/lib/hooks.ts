"use client";
import { useReadContract } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { ADDR, VIEWS_ABI, STOCKS } from "./ass";

/* ---------- on-chain (AssViews = source of truth) ---------- */

export function useProtocolStats() {
  return useReadContract({
    address: ADDR.views, abi: VIEWS_ABI, functionName: "protocolStats",
    query: { refetchInterval: 30_000 },
  });
}

export function useAssetCards() {
  return useReadContract({
    address: ADDR.views, abi: VIEWS_ABI, functionName: "assetCards",
    query: { refetchInterval: 30_000 },
  });
}

export function useHolderCard(address?: `0x${string}`) {
  return useReadContract({
    address: ADDR.views, abi: VIEWS_ABI, functionName: "holderCard",
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 30_000 },
  });
}

/* ---------- market data (Dexscreener; null until pairs exist) ---------- */

export type MarketData = { priceUsd: number | null; change24h: number | null; volume24h: number | null };

async function fetchDex(token: string): Promise<MarketData> {
  const r = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${token}`);
  if (!r.ok) return { priceUsd: null, change24h: null, volume24h: null };
  const j = await r.json();
  const pairs = (j.pairs ?? []).filter((p: any) => p.chainId === "bsc");
  if (!pairs.length) return { priceUsd: null, change24h: null, volume24h: null };
  // one pair per token, highest liquidity (Loxley rule: never the multi-token endpoint)
  const best = pairs.sort((a: any, b: any) => (b.liquidity?.usd ?? 0) - (a.liquidity?.usd ?? 0))[0];
  return {
    priceUsd: best.priceUsd ? Number(best.priceUsd) : null,
    change24h: best.priceChange?.h24 ?? null,
    volume24h: best.volume?.h24 ?? null,
  };
}

/** $ASS + the three bStocks, one call each, 60s refresh */
export function useMarkets() {
  return useQuery({
    queryKey: ["markets"],
    queryFn: async () => {
      const [ass, ...stocks] = await Promise.all([
        fetchDex(ADDR.token),
        ...STOCKS.map((s) => fetchDex(s.address)),
      ]);
      return {
        ass,
        stocks: Object.fromEntries(STOCKS.map((s, i) => [s.symbol, stocks[i]])) as Record<string, MarketData>,
      };
    },
    refetchInterval: 60_000,
  });
}

/* ---------- display helpers ---------- */
export const usd = (n: number | null | undefined, dp = 2) =>
  n == null ? "—" : `$${n.toLocaleString("en-GB", { maximumFractionDigits: dp, minimumFractionDigits: n < 1 ? 4 : dp })}`;
export const pct = (n: number | null | undefined) =>
  n == null ? "" : `${n >= 0 ? "+" : ""}${n.toFixed(2)}%`;