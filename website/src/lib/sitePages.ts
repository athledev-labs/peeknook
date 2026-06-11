// SPDX-License-Identifier: Apache-2.0

export type SiteCurrent =
  | "home"
  | "features"
  | "docs"
  | "faq"
  | "changelog"
  | "privacy"
  | "licenses"
  | "terms";

export const SITE_ORIGIN = "https://glendonc.github.io";
export const SITE_BASE = "/peeknook";

/** Astro `BASE_URL` omits a trailing slash when `trailingSlash` is not `always`. */
export function normalizeBase(base: string): string {
  return base.endsWith("/") ? base : `${base}/`;
}

/** Join base + path segment (e.g. `/peeknook` + `features/` → `/peeknook/features/`). */
export function sitePath(base: string, path = ""): string {
  const root = normalizeBase(base);
  if (!path) return root;
  return `${root}${path.replace(/^\//, "")}`;
}

export function siteURL(path = ""): string {
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${SITE_ORIGIN}${SITE_BASE}${normalized}`.replace(/\/{2,}/g, "/").replace(":/", "://");
}
