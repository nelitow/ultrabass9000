#!/usr/bin/env bash
set -euo pipefail

# Derives the release tag from project.yml's MARKETING_VERSION plus the
# commit count on the current branch, so every commit on main gets a
# unique, reproducible tag without depending on GitHub Actions run numbers
# (which reset if the workflow file is ever recreated).
#
# Usage: scripts/derive-version.sh
# Prints three `key=value` lines to stdout, one per line:
#   version=0.1.0
#   tag=v0.1.0-42
#   zip_name=UltraBass9000-0.1.0-42.zip
#
# In CI this output is appended straight to $GITHUB_OUTPUT. It also runs
# fine on a plain local checkout for testing.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_yml="$repo_root/project.yml"

if [[ ! -f "$project_yml" ]]; then
  echo "error: $project_yml not found" >&2
  exit 1
fi

marketing_version="$(grep -E '^[[:space:]]*MARKETING_VERSION:' "$project_yml" \
  | head -n1 \
  | sed -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/')"

if [[ -z "$marketing_version" ]]; then
  echo "error: could not read MARKETING_VERSION out of project.yml" >&2
  exit 1
fi

# Requires full history (actions/checkout with fetch-depth: 0); on a shallow
# clone this undercounts and tags could collide.
commit_count="$(git -C "$repo_root" rev-list --count HEAD)"

tag="v${marketing_version}-${commit_count}"
zip_name="UltraBass9000-${marketing_version}-${commit_count}.zip"

echo "version=${marketing_version}"
echo "tag=${tag}"
echo "zip_name=${zip_name}"
