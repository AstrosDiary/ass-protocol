import { http, createConfig } from "wagmi";
import { bsc } from "wagmi/chains";
import { injected, walletConnect } from "wagmi/connectors";
import { RPC } from "./ass";

const pid = process.env.NEXT_PUBLIC_REOWN_PROJECT_ID;

export const config = createConfig({
  chains: [bsc], // BSC only — mainnet-first rule trivially satisfied
  connectors: [injected(), ...(pid ? [walletConnect({ projectId: pid })] : [])],
  transports: { [bsc.id]: http(RPC) },
  ssr: false, // static export
});