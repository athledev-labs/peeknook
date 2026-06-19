// SPDX-License-Identifier: Apache-2.0
import { defineConfig } from "astro/config";

// GitHub Pages served from the custom apex domain: https://peeknook.com/
export default defineConfig({
  site: "https://peeknook.com",
  trailingSlash: "ignore",
  redirects: {
    "/download/": "/docs/",
    "/refunds/": "/faq/",
    "/support/": "/faq/",
  },
});
