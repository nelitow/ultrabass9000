#!/usr/bin/env bash
set -euo pipefail

# Builds the GitHub release body: the unsigned-build Gatekeeper warning
# (required reading — the download will not open without it) followed by
# a "What's changed" list of commits since the previous release tag.
#
# Usage: scripts/release-notes.sh <new-tag>
# Prints the release body markdown to stdout.

new_tag="${1:?usage: release-notes.sh <new-tag>}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

repo_slug="${GITHUB_REPOSITORY:-nelitow/ultrabass9000}"
commit_sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"

# Nearest ancestor tag reachable from HEAD, if any. First release has none.
# (new_tag itself never exists locally yet at this point — it's created by
# `gh release create` after this script runs.)
previous_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"

if [[ -n "$previous_tag" ]]; then
  range="${previous_tag}..HEAD"
  changes_heading="## What's changed since \`${previous_tag}\`"
  compare_line="Full diff: https://github.com/${repo_slug}/compare/${previous_tag}...${new_tag}"
else
  range="HEAD"
  changes_heading="## What's changed"
  compare_line="Initial automated release — commit history below is everything up to this point."
fi

commit_list="$(git log "$range" --no-merges --pretty=format:'- %s (%h)' 2>/dev/null || true)"
if [[ -z "$commit_list" ]]; then
  commit_list="- No user-facing commits since the last release."
fi

cat <<EOF
## This build is unsigned — read this before downloading

UltraBass9000 is not signed with an Apple Developer ID and is not notarized. macOS
Gatekeeper will refuse to open it and say **"UltraBass9000.app is damaged and can't be
opened."** That message is misleading — the app isn't damaged. To open it:

1. Unzip the asset below.
2. Right-click (Control-click) \`UltraBass9000.app\` → **Open** → confirm **Open** in the
   dialog that appears.
3. If macOS doesn't offer an "Open" option at all, remove the quarantine flag from
   Terminal instead:
   \`\`\`sh
   xattr -dr com.apple.quarantine /path/to/UltraBass9000.app
   \`\`\`

This only needs to be done once per download.

**Known limitation:** even after it opens, this build cannot get the Core Audio
permission prompt it needs for its main feature — see "Known limitation: unsigned
release builds are functionally silent" in
[RELEASING.md](https://github.com/${repo_slug}/blob/main/RELEASING.md) before relying on
it. Fixing this for real requires a paid Apple Developer ID and notarization, also
documented there.

${changes_heading}

${commit_list}

${compare_line}

---
Built automatically from \`${commit_sha}\` on push to \`main\`. Unsigned, unnotarized —
see above.
EOF
