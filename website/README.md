# SPDX-License-Identifier: Apache-2.0

Static marketing site for Peeknook.

## Develop

```sh
cd website
npm install
npm run dev
```

Open http://localhost:4321/peeknook/ (base path matches GitHub Pages).

## Build

```sh
npm run build
```

Markdown pages render from the repo root at build time:

| Site path | Source |
|-----------|--------|
| `/docs/` | `INSTALL.md` |
| `/privacy/` | `PRIVACY.md` |
| `/licenses/` | `NOTICE` |
| `/terms/` | `TERMS.md` |
| `/faq/` | `FAQ.md` |

Changelog and download metadata fetch [GitHub Releases](https://github.com/athledev-labs/peeknook/releases) at build time.

## Deploy

Push to `main`: `.github/workflows/pages.yml` publishes to https://peeknook.com/ (GitHub Pages on the custom apex domain; `public/CNAME` pins it).

## Site standards

Static site: pages are pre-rendered HTML. No app-style loading spinners.

| Concern | Approach |
|---------|----------|
| **404** | `src/pages/404.astro` becomes `404.html` (GitHub Pages serves this for bad paths) |
| **Loading** | System fonts only: no webfont fetch, no flash |
| **Motion** | `prefers-reduced-motion` disables animations |
| **Focus** | Visible `:focus-visible` rings; skip link to `#main-content` |
| **SEO errors** | 404 uses `noindex` |
| **Release data** | Fetched at **build** time (CI), not in the browser |

When you add payments or client-side features later, revisit loading/error UI then, not before.
