import { parseAbi, type Address, formatUnits } from "viem";

const req = (v: string | undefined, name: string): Address => {
  if (!v) throw new Error(`env ${name} missing — set it in .env.local`);
  return v as Address;
};

export const ADDR = {
  token: req(process.env.NEXT_PUBLIC_TOKEN, "TOKEN"),
  vault: req(process.env.NEXT_PUBLIC_VAULT, "VAULT"),
  tracker: req(process.env.NEXT_PUBLIC_TRACKER, "TRACKER"),
  engine: req(process.env.NEXT_PUBLIC_ENGINE, "ENGINE"),
  distributor: req(process.env.NEXT_PUBLIC_DISTRIBUTOR, "DISTRIBUTOR"),
  views: req(process.env.NEXT_PUBLIC_VIEWS, "VIEWS"),
} as const;

export const RPC = process.env.NEXT_PUBLIC_BSC_RPC ?? "https://bsc-dataseed.bnbchain.org";
export const INDEXER = process.env.NEXT_PUBLIC_INDEXER_URL || null;

/** quote token: QQQB (Invesco QQQ Trust bStock) — the pairing + tax currency */
export const QQQB = "0x205812CdBed920aFf76C6580abD681a46D11efc7" as Address;

/** the three-asset basket — final, per project ruling */
export const STOCKS = [
  { symbol: "BABAB", name: "Alibaba Group", region: "China",
    address: "0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec" as Address },
  { symbol: "TSMB", name: "Taiwan Semiconductor", region: "Taiwan",
    address: "0xAB78b89B5bb00236Be0B4B20704cBfa04EfC711c" as Address },
  { symbol: "SKHYB", name: "SK Hynix", region: "South Korea",
    address: "0xCA750eF65f295BBECd685Abf54e82CAf297BDB61" as Address },
] as const;

export const VIEWS_ABI = parseAbi([
  "function VERSION() view returns (string)",
  "struct ProtocolStats { uint256 vaultTotalReceivedQuote; uint256 vaultTotalReleasedQuote; uint256 vaultPendingQuote; uint256 engineUnallocatedQuote; uint256 cumulativeQuoteProcessed; uint256 trackerTotalShares; uint256 trackerMinimumShare; uint8 distributorPhase; uint64 currentCycleId; uint256 assetCount; }",
  "struct AssetCard { address asset; bool enabledEngine; bool enabledDistributor; uint16 weightBps; uint128 maxSpendPerBuy; uint256 budgetQuote; uint256 cumulativeSpentQuote; uint256 cumulativeBoughtRaw; uint256 cumulativeDistributedRaw; uint256 distributorBalanceRaw; uint256 reservedForAccruedRaw; uint256 minPayoutRaw; }",
  "struct HolderCard { uint256 trackerShare; bool excluded; uint256[] accruedRaw; }",
  "function protocolStats() view returns (ProtocolStats)",
  "function assetCards() view returns (AssetCard[])",
  "function holderCard(address h) view returns (HolderCard)",
]);

export const TRACKER_ABI = parseAbi([
  "function userInfo(address) view returns (uint256 share, uint256 rewardDebt, uint256 pending)",
  "function totalShares() view returns (uint256)",
  "function minimumShareBalance() view returns (uint256)",
]);

export const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);

/* ---------------- canonical formatting layer (spec-mandated) ---------------- */

/** THE one formatter for bStock quantities everywhere. Raw units in;
 * BEP-677 display multiplier applied HERE and only here (1e18 = neutral
 * until the indexer serves live multipliers). */
export function formatBStockAmount(raw: bigint, multiplier: bigint = 10n ** 18n): string {
  const scaled = (raw * multiplier) / 10n ** 18n;
  return fmtUnits(scaled, 18);
}

/** sig-fig aware units formatter — dust never renders as 0.00 (Loxley lesson) */
export function fmtUnits(raw: bigint, decimals = 18, maxSig = 4): string {
  if (raw === 0n) return "0";
  const s = formatUnits(raw, decimals);
  const n = Number(s);
  if (n >= 1000) return n.toLocaleString("en-GB", { maximumFractionDigits: 2 });
  if (n >= 1) return n.toLocaleString("en-GB", { maximumFractionDigits: 4 });
  return n.toPrecision(maxSig).replace(/\.?0+$/, "");
}

export const fmtQuote = (raw: bigint) => `${fmtUnits(raw, 18)} QQQB`;
export const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;