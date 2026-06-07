// SPDX-License-Identifier: Apache-2.0

/** Pin release assets here; swap to GitHub API fetch on next ship. */
export const release = {
  version: "0.1.0",
  dmgURL:
    "https://github.com/glendonC/peeknook/releases/download/v0.1.0/Peeknook-0.1.0.dmg",
  dmgSHA256:
    "2e2b8c6cc278c2fd12767483d13ae8bdcac26270128b7fa5f5e3b3c70c3cc7a5",
  zipURL:
    "https://github.com/glendonC/peeknook/releases/download/v0.1.0/Peeknook.zip",
  releasesURL: "https://github.com/glendonC/peeknook/releases/tag/v0.1.0",
  latestReleasesURL:
    "https://github.com/glendonC/peeknook/releases/latest",
} as const;
