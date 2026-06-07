# SPDX-License-Identifier: Apache-2.0

Static marketing site for Peeknook (home, install guide, privacy, licenses).

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

Output goes to `website/dist/`. Privacy and licenses pages render `PRIVACY.md` and `NOTICE` from the repo root at build time.

## Deploy (GitHub Pages)

Push to `main` with the `website/` folder present. The workflow in `.github/workflows/pages.yml` builds and publishes to:

https://glendonc.github.io/peeknook/

Release download URLs are pinned in `src/data/release.ts` (v0.1.0 today). Update that file on each ship, or automate with the GitHub Releases API later.

## Custom domain (later)

Set `site` and `base` in `astro.config.mjs`, then point DNS at GitHub Pages or Cloudflare.
