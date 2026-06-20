// SPDX-License-Identifier: Apache-2.0

const REPO = "glendonC/peeknook";
const RELEASES_HOST = "https://github.com";
const ALLOWED_DOWNLOAD_PREFIX = `${RELEASES_HOST}/${REPO}/releases/download/`;

export type ReleaseInfo = {
  version: string;
  tagName: string;
  dmgURL: string;
  dmgSHA256: string | null;
  zipURL: string | null;
  releasesURL: string;
  latestReleasesURL: string;
};

type GitHubAsset = {
  name: string;
  browser_download_url: string;
  digest?: string | null;
};

type GitHubRelease = {
  tag_name: string;
  html_url: string;
  assets: GitHubAsset[];
};

/** Offline / API-failure fallback — bump when cutting a release if builds run without network. */
const FALLBACK: ReleaseInfo = {
  version: "0.2.0",
  tagName: "v0.2.0",
  dmgURL: `${ALLOWED_DOWNLOAD_PREFIX}v0.2.0/Peeknook-0.2.0.dmg`,
  dmgSHA256: "2f9ea980c3a01332c68f95f60e649e4a31516fc8af28e3683667c6f98b8b4547",
  zipURL: `${ALLOWED_DOWNLOAD_PREFIX}v0.2.0/Peeknook.zip`,
  releasesURL: `${RELEASES_HOST}/${REPO}/releases/tag/v0.2.0`,
  latestReleasesURL: `${RELEASES_HOST}/${REPO}/releases/latest`,
};

let releasePromise: Promise<ReleaseInfo> | undefined;

export function getRelease(): Promise<ReleaseInfo> {
  if (!releasePromise) {
    releasePromise = fetchLatestRelease();
  }
  return releasePromise;
}

function assertTrustedDownloadURL(url: string): string {
  if (!url.startsWith(ALLOWED_DOWNLOAD_PREFIX)) {
    throw new Error(`Untrusted release asset URL: ${url}`);
  }
  return url;
}

function parseDigest(digest: string | null | undefined): string | null {
  if (!digest?.startsWith("sha256:")) return null;
  const hex = digest.slice("sha256:".length);
  return /^[a-f0-9]{64}$/i.test(hex) ? hex.toLowerCase() : null;
}

function pickDmg(assets: GitHubAsset[]): GitHubAsset | undefined {
  const dmgs = assets.filter((asset) => asset.name.toLowerCase().endsWith(".dmg"));
  return (
    dmgs.find((asset) => asset.name === "Peeknook.dmg") ??
    dmgs.find((asset) => /^Peeknook-\d/.test(asset.name)) ??
    dmgs[0]
  );
}

function pickZip(assets: GitHubAsset[]): GitHubAsset | undefined {
  return (
    assets.find((asset) => asset.name === "Peeknook.zip") ??
    assets.find((asset) => asset.name.toLowerCase().endsWith(".zip"))
  );
}

async function fetchLatestRelease(): Promise<ReleaseInfo> {
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
      `https://api.github.com/repos/${REPO}/releases/latest`,
      {
        headers,
        signal: AbortSignal.timeout(12_000),
      },
    );

    if (!response.ok) {
      throw new Error(`GitHub API ${response.status}`);
    }

    const data = (await response.json()) as GitHubRelease;
    const dmg = pickDmg(data.assets ?? []);
    if (!dmg) {
      throw new Error("Latest release has no .dmg asset");
    }

    const zip = pickZip(data.assets ?? []);
    const version = data.tag_name.replace(/^v/, "");

    return {
      version,
      tagName: data.tag_name,
      dmgURL: assertTrustedDownloadURL(dmg.browser_download_url),
      dmgSHA256: parseDigest(dmg.digest),
      zipURL: zip
        ? assertTrustedDownloadURL(zip.browser_download_url)
        : null,
      releasesURL: data.html_url,
      latestReleasesURL: `${RELEASES_HOST}/${REPO}/releases/latest`,
    };
  } catch (error) {
    console.warn("[release] Using fallback metadata:", error);
    return FALLBACK;
  }
}
