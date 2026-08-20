"use client";
import { useReadContract, useReadContracts } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { ERC20_ABI, TRACKER_ABI, ADDR, VIEWS_ABI, STOCKS, INDEXER } from "./ass";

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

export function useWallet(address?: `0x${string}`) {
  return useReadContracts({
    contracts: address ? [
      ...STOCKS.map((s) => ({ address: s.address, abi: ERC20_ABI, functionName: "balanceOf" as const, args: [address] as const })),
      { address: ADDR.token, abi: ERC20_ABI, functionName: "balanceOf" as const, args: [address] as const },
      { address: ADDR.tracker, abi: TRACKER_ABI, functionName: "userInfo" as const, args: [address] as const },
      { address: ADDR.tracker, abi: TRACKER_ABI, functionName: "minimumShareBalance" as const },
    ] : [],
    query: { enabled: !!address, refetchInterval: 30_000 },
  });
}

export function useHolderHistory(address?: `0x${string}`) {
  return useQuery({
    queryKey: ["idx-holder", address],
    queryFn: async () => (await fetch(`${INDEXER}/holder/${address}`)).json() as Promise<{
      share: string; paid: { ts: number; tx: string; asset: string; amount: string }[];
    }>,
    enabled: !!INDEXER && !!address, refetchInterval: 30_000,
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

export function useIndexerProtocol() {
  return useQuery({
    queryKey: ["idx-protocol"],
    queryFn: async () => (await fetch(`${INDEXER}/protocol`)).json() as Promise<{
      holders: number; cumProcessed: string; history: { day: string; cum: string }[];
    }>,
    enabled: !!INDEXER, refetchInterval: 30_000,
  });
}

export function useExecutionFeed() {
  return useQuery({
    queryKey: ["idx-feed"],
    queryFn: async () => (await fetch(`${INDEXER}/feed`)).json() as Promise<{
      ts: number; block: number; tx: string; action: string; asset: string; quoteSpent: string; received: string;
    }[]>,
    enabled: !!INDEXER, refetchInterval: 30_000,
  });
}

/* ---------- display helpers ---------- */
export const usd = (n: number | null | undefined, dp = 2) => {
  if (n == null) return "—";
  const decimals = n !== 0 && Math.abs(n) < 1 ? Math.max(dp, 4) : dp;
  return `$${n.toLocaleString("en-GB", { minimumFractionDigits: Math.min(decimals, dp), maximumFractionDigits: decimals })}`;
};
export const pct = (n: number | null | undefined) =>
  n == null ? "" : `${n >= 0 ? "+" : ""}${n.toFixed(2)}%`;