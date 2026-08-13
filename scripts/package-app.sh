#!/usr/bin/env bash
set -euo pipefail

# Ad-hoc signs a built .app bundle and zips it with `ditto` (not `zip`, so
# resource forks / extended attributes / the bundle structure survive
# intact). Used by the release workflow after `xcodebuild ... test`, and
# safe to run locally against your own Release build to sanity-check the
# exact artifact a downloader would receive.
#
# IMPORTANT: ad-hoc signing (`codesign --sign -`) is NOT a Developer ID
# signature and does not make this a "signed build" in any meaningful
# sense. It only makes the "right-click > Open" / `xattr -dr
# com.apple.quarantine` Gatekeeper workaround reliably apply to the
# downloaded bundle. It does NOT satisfy TCC for the Core Audio process
# tap this app relies on — that needs the real DEVELOPMENT_TEAM identity
# configured in project.yml, which CI does not have access to. See the
# "Known limitation" section in RELEASING.md.
#
# Usage: scripts/package-app.sh <path-to-.app> <path-to-output.zip>

app_path="${1:?usage: package-app.sh <path-to-.app> <path-to-output.zip>}"
zip_path="${2:?usage: package-app.sh <path-to-.app> <path-to-output.zip>}"

if [[ ! -d "$app_path" ]]; then
  echo "error: app bundle not found at $app_path" >&2
  exit 1
fi

echo "==> Ad-hoc signing $app_path (see script header — this is not real signing)"
codesign --force --deep --sign - "$app_path"

echo "==> Verifying the ad-hoc signature is at least internally consistent"
codesign --verify --deep --strict "$app_path"

mkdir -p "$(dirname "$zip_path")"
rm -f "$zip_path"

echo "==> Zipping with ditto -> $zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"

echo "zip_path=$zip_path"
