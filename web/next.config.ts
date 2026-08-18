import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

const withNextIntl = createNextIntlPlugin("./src/i18n/request.ts");

const nextConfig: NextConfig = {
  output: "export",
  images: { unoptimized: true },
  turbopack: {
    resolveAlias: {
      "@x402/core/client": "./src/lib/empty.ts",
      "@x402/svm/exact/client": "./src/lib/empty.ts",
      "@x402/evm/exact/client": "./src/lib/empty.ts",
      "@x402/evm/upto/client": "./src/lib/empty.ts",
      "@x402/evm": "./src/lib/empty.ts",
    },
  },
  // dev-only proxy so /indexer works locally too (ignored in static export)
  async rewrites() {
    return [{ source: "/indexer/:path*", destination: "http://192.248.162.191:8788/:path*" }];
  },
};

export default withNextIntl(nextConfig);