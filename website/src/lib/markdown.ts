// SPDX-License-Identifier: Apache-2.0
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { marked, Renderer } from "marked";

const repoRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

export type DocHeading = {
  id: string;
  text: string;
  level: number;
};

export type RenderedMarkdown = {
  html: string;
  headings: DocHeading[];
};

marked.setOptions({
  gfm: true,
  breaks: false,
});

const renderer = new Renderer();
renderer.heading = function (heading) {
  const text = this.parser.parseInline(heading.tokens);
  const id = slugify(stripTags(text));
  return `<h${heading.depth} id="${id}">${text}</h${heading.depth}>\n`;
};

marked.use({ renderer });

function stripTags(html: string): string {
  return html.replace(/<[^>]+>/g, "");
}

function slugify(text: string): string {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

function stripMarkdownInline(text: string): string {
  return text.replace(/\*\*/g, "").replace(/`/g, "").trim();
}

export function extractHeadings(source: string): DocHeading[] {
  const headings: DocHeading[] = [];

  for (const line of source.split("\n")) {
    const match = line.match(/^(#{1,3})\s+(.+)$/);
    if (!match) continue;

    const level = match[1].length;
    const text = stripMarkdownInline(match[2]);
    headings.push({ level, text, id: slugify(text) });
  }

  return headings;
}

function wrapH2Sections(html: string): string {
  const sections = html.split(/(?=<h2[\s>])/);
  if (sections.length <= 1) return html;

  const [lead, ...rest] = sections;
  return (
    lead +
    rest
      .map((section) => `<div class="prose-section">${section}</div>`)
      .join("")
  );
}

export function renderRepoMarkdown(relativePath: string): RenderedMarkdown {
  const absolutePath = path.join(repoRoot, relativePath);
  const source = fs.readFileSync(absolutePath, "utf8");
  const headings = extractHeadings(source);
  const html = wrapH2Sections(marked.parse(source) as string);

  return { html, headings };
}
