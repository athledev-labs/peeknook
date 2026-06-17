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

/** Drop em dashes (and number-range en dashes) from rendered copy. */
function tidyDashes(text: string): string {
  return text
    .replace(/(\d)\s*[–—]\s*(\d)/g, "$1-$2")
    .replace(/\s*—\s*/g, ", ");
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

function stripLeadingH1(html: string): string {
  return html.replace(/^\s*<h1[^>]*>[\s\S]*?<\/h1>\s*/i, "");
}

export type RenderMarkdownOptions = {
  stripLeadingH1?: boolean;
};

export function renderRepoMarkdown(
  relativePath: string,
  options: RenderMarkdownOptions = {},
): RenderedMarkdown {
  const absolutePath = path.join(repoRoot, relativePath);
  const source = tidyDashes(fs.readFileSync(absolutePath, "utf8"));
  const headings = extractHeadings(source);
  let html = marked.parse(source) as string;

  if (options.stripLeadingH1) {
    html = stripLeadingH1(html);
  }

  return { html, headings };
}

export type DocItem = { id: string; title: string; html: string };

export type DocSection = {
  id: string;
  title: string;
  step: string | null;
  html: string;
  items: DocItem[];
};

export type ParsedSections = {
  intro: string;
  sections: DocSection[];
};

/**
 * Parse a repo markdown file into structured sections (`##`) and items (`###`)
 * so pages can render designed components instead of a flat markdown blob.
 * Section titles that begin with "N." expose `step` for numbered step badges.
 */
export function parseRepoMarkdownSections(relativePath: string): ParsedSections {
  const absolutePath = path.join(repoRoot, relativePath);
  const source = tidyDashes(fs.readFileSync(absolutePath, "utf8"));
  const tokens = marked.lexer(source);
  const links = (tokens as unknown as { links?: unknown }).links;

  type Tok = { type: string; depth?: number; text?: string };
  type RawItem = { title: string; id: string; tokens: unknown[] };
  type RawSection = {
    title: string;
    step: string | null;
    id: string;
    bodyTokens: unknown[];
    items: RawItem[];
  };

  const withLinks = (arr: unknown[]) => {
    (arr as unknown as { links?: unknown }).links = links;
    return arr as Parameters<typeof marked.parser>[0];
  };

  const sections: RawSection[] = [];
  const introTokens: unknown[] = [];
  let cur: RawSection | null = null;
  let curItem: RawItem | null = null;

  for (const token of tokens) {
    const t = token as Tok;
    if (t.type === "heading" && t.depth === 1) continue;
    if (t.type === "heading" && t.depth === 2) {
      const text = t.text ?? "";
      const stepMatch = text.match(/^(\d+)\.\s+(.*)$/);
      cur = {
        title: stepMatch ? stepMatch[2] : text,
        step: stepMatch ? stepMatch[1] : null,
        id: slugify(stripTags(text)),
        bodyTokens: [],
        items: [],
      };
      curItem = null;
      sections.push(cur);
      continue;
    }
    if (t.type === "heading" && t.depth === 3 && cur) {
      const text = t.text ?? "";
      curItem = { title: text, id: slugify(stripTags(text)), tokens: [] };
      cur.items.push(curItem);
      continue;
    }
    if (curItem) curItem.tokens.push(token);
    else if (cur) cur.bodyTokens.push(token);
    else introTokens.push(token);
  }

  return {
    intro: marked.parser(withLinks(introTokens)),
    sections: sections.map((s) => ({
      id: s.id,
      title: marked.parseInline(s.title) as string,
      step: s.step,
      html: marked.parser(withLinks(s.bodyTokens)),
      items: s.items.map((it) => ({
        id: it.id,
        title: marked.parseInline(it.title) as string,
        html: marked.parser(withLinks(it.tokens)),
      })),
    })),
  };
}
