// SPDX-License-Identifier: Apache-2.0
import { defineConfig } from "astro/config";

// GitHub Pages project site: https://glendonc.github.io/peeknook/
export default defineConfig({
  site: "https://glendonc.github.io",
  base: "/peeknook",
  trailingSlash: "always",
});
