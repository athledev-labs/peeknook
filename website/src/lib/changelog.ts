// SPDX-License-Identifier: Apache-2.0
import { marked } from "marked";

const REPO = "glendonC/peeknook";

export type ChangelogEntry = {
  tagName: string;
  version: string;
  publishedAt: string;
  url: string;
  bodyHtml: string;
};

type GitHubRelease = {
  tag_name: string;
  html_url: string;
  published_at: string;
  body: string | null;
  draft: boolean;
  prerelease: boolean;
};

const FALLBACK: ChangelogEntry[] = [
  {
    tagName: "v0.1.0",
    version: "0.1.0",
    publishedAt: "2026-06-07T02:46:33Z",
    url: "https://github.com/glendonC/peeknook/releases/tag/v0.1.0",
    bodyHtml: marked.parse(
      `First notarized direct-download release.

- Capture and answer from the notch with **⌘⇧P**
- Local-only inference via Ollama
- Optional conversation archive, usage stats, and model library`,
    ) as string,
  },
];

let changelogPromise: Promise<ChangelogEntry[]> | undefined;

export function getChangelog(): Promise<ChangelogEntry[]> {
  if (!changelogPromise) {
    changelogPromise = fetchChangelog();
  }
  return changelogPromise;
}

async function fetchChangelog(): Promise<ChangelogEntry[]> {
  try {
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": "peeknook-website",
    };
    const token = process.env.GITHUB_TOKEN;
    if (token) {
      headers.Authorization = `Bearer ${token}`;
    }

    const response = await fetch(
      `https://api.github.com/repos/${REPO}/releases?per_page=20`,
      {
        headers,
        signal: AbortSignal.timeout(12_000),
      },
    );

    if (!response.ok) {
      throw new Error(`GitHub API ${response.status}`);
    }

    const data = (await response.json()) as GitHubRelease[];
    const published = data.filter((release) => !release.draft && !release.prerelease);

    if (published.length === 0) {
      return FALLBACK;
    }

    return published.map((release) => ({
      tagName: release.tag_name,
      version: release.tag_name.replace(/^v/, ""),
      publishedAt: release.published_at,
      url: release.html_url,
      bodyHtml: marked.parse(release.body?.trim() || "_No release notes._") as string,
    }));
  } catch (error) {
    console.warn("[changelog] Using fallback entries:", error);
    return FALLBACK;
  }
}

export function formatReleaseDate(iso: string): string {
  return new Intl.DateTimeFormat("en-US", {
    dateStyle: "long",
    timeZone: "UTC",
  }).format(new Date(iso));
}
