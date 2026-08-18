import type { NextConfig } from "next";
import createNextIntlPlugin from "next-intl/plugin";

const withNextIntl = createNextIntlPlugin("./src/i18n/request.ts");

const nextConfig: NextConfig = {
  output: "export",
  images: { unoptimized: true },
  // dev-only proxy so /indexer works locally too (ignored in static export)
  async rewrites() {
    return [{ source: "/indexer/:path*", destination: "http://192.248.162.191:8788/:path*" }];
  },
};

export default withNextIntl(nextConfig);