import { http, createConfig, type Config } from "wagmi";
import { bsc } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { WagmiAdapter } from "@reown/appkit-adapter-wagmi";
import { createAppKit } from "@reown/appkit/react";
import { RPC } from "./ass";

const pid = process.env.NEXT_PUBLIC_REOWN_PROJECT_ID;
export const HAS_APPKIT = !!pid;

let cfg: Config;

if (pid) {
  const adapter = new WagmiAdapter({
    networks: [bsc],
    projectId: pid,
    ssr: false,
    transports: { [bsc.id]: http(RPC) },
  });
  createAppKit({
    adapters: [adapter],
    networks: [bsc],
    defaultNetwork: bsc,
    projectId: pid,
    metadata: {
      name: "Asian Stock Strategy ($ASS)",
      description: "Hold $ASS and automatically accrue Asian bStocks in your wallet.",
      url: "https://asianstockstrategy.com",          // must match your live domain
      icons: ["https://asianstockstrategy.com/brand/logo.png"],
    },
    themeMode: "dark",
    themeVariables: {
      "--w3m-accent": "#7137D6",
      "--w3m-color-mix": "#0B0D18",
      "--w3m-color-mix-strength": 20,
      "--w3m-border-radius-master": "2px",
    },
    features: { analytics: false, email: false, socials: false }, // wallets only — no web2 login clutter
  });
  cfg = adapter.wagmiConfig;
} else {
  // fallback: pre-AppKit injected-only flow (dev without projectId)
  cfg = createConfig({
    chains: [bsc],
    connectors: [injected()],
    transports: { [bsc.id]: http(RPC) },
    ssr: false,
  });
}

export const config = cfg;