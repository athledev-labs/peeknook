// SPDX-License-Identifier: Apache-2.0
import {
  CircleAlert,
  FileText,
  LayoutGrid,
  Scale,
  ShieldCheck,
  Tag,
} from "lucide-static";

export type SiteIconName =
  | "features"
  | "docs"
  | "releases"
  | "github"
  | "privacy"
  | "licenses"
  | "issues";

/** Strip Lucide defaults so CSS controls size; keep stroke styling. */
function normalizeLucideSvg(svg: string): string {
  return svg
    .replace(/\sclass="[^"]*"/, "")
    .replace(/\sxmlns="[^"]*"/, "")
    .replace(/\swidth="24"/, "")
    .replace(/\sheight="24"/, "")
    .replace("<svg", '<svg aria-hidden="true"');
}

const githubMark = `<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" clip-rule="evenodd" d="M8 1.25a6.75 6.75 0 0 0-2.135 13.16c.338.063.462-.147.462-.326 0-.161-.006-.583-.01-1.145A4.72 4.72 0 0 1 4.86 13.2c-.418.226-.9-.113-.9-.113-.308-.208-.64-.287-.64-.287-.523-.358.04-.351.04-.351.578.041.883.594.883.594.515.883 1.35.628 1.68.48.052-.373.201-.628.365-.772-1.28-.145-2.627-.64-2.627-2.85 0-.63.225-1.144.594-1.548-.06-.145-.26-.735.056-1.533 0 0 .484-.155 1.585.592a5.48 5.48 0 0 1 1.44-.194c.49-.007.984.066 1.44.194 1.1-.747 1.583-.592 1.583-.592.318.798.118 1.388.058 1.533.37.404.593.918.593 1.548 0 2.217-1.35 2.702-2.635 2.843.207.178.39.528.39 1.066 0 .77-.007 1.39-.007 1.578 0 .18.122.392.467.326A6.75 6.75 0 0 0 8 1.25Z"/></svg>`;

export const siteIconSvg: Record<SiteIconName, string> = {
  features: normalizeLucideSvg(LayoutGrid),
  docs: normalizeLucideSvg(FileText),
  releases: normalizeLucideSvg(Tag),
  github: githubMark,
  privacy: normalizeLucideSvg(ShieldCheck),
  licenses: normalizeLucideSvg(Scale),
  issues: normalizeLucideSvg(CircleAlert),
};
