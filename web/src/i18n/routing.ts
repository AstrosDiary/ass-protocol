import { defineRouting } from "next-intl/routing";
import { createNavigation } from "next-intl/navigation";

export const routing = defineRouting({
  locales: ["en", "zh"],
  defaultLocale: "en",
  localePrefix: "always", // static export: every route is /en/* or /zh/*
});

export const { Link, usePathname, useRouter } = createNavigation(routing);
