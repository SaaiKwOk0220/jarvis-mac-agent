#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
if [ -n "${JARVIS_CONTROLLED_GRDB_PATH:-}" ]; then
  : "${JARVIS_GRDB_SOURCE_REPO:?Controlled build requires verified upstream repository}"
  : "${JARVIS_GRDB_CACHE_DIR:?Controlled build requires cache directory}"
  verified="$("$script_dir/prepare-controlled-grdb.sh" "$JARVIS_GRDB_SOURCE_REPO" "$JARVIS_GRDB_CACHE_DIR")"
  if [ "$verified" != "$JARVIS_CONTROLLED_GRDB_PATH" ]; then echo 'Controlled GRDB path is not verified' >&2; exit 1; fi
  /usr/bin/python3 - "$package_dir/Package.swift" "$verified" <<'PYMANIFEST'
from pathlib import Path
import json, sys
text = Path(sys.argv[1]).read_text()
expected = '.package(name: "GRDB.swift", path: ' + json.dumps(sys.argv[2]) + ')'
if text.count(expected) != 1 or 'https://github.com/groue/GRDB.swift.git' in text:
    raise SystemExit('Controlled GRDB manifest is not bound to the verified source')
PYMANIFEST
fi
output_dir="${1:-$package_dir/.build/dev-app}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
swift build --package-path "$package_dir" --product JarvisMenuBar >&2
bin_dir="$(swift build --package-path "$package_dir" --show-bin-path)"
bundle_dir="$(mktemp -d "$output_dir/Jarvis.XXXXXX")"
app_dir="$bundle_dir/Jarvis.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp "$bin_dir/JarvisMenuBar" "$app_dir/Contents/MacOS/JarvisMenuBar"
if [ -n "${JARVIS_CONTROLLED_GRDB_PATH:-}" ]; then
  privacy="$JARVIS_CONTROLLED_GRDB_PATH/GRDB/PrivacyInfo.xcprivacy"
  test "$(shasum -a 256 "$privacy" | cut -d ' ' -f 1)" = 17784da62e51f74c5859df32fe402e01e25cdf6f797a4add06e2a3ce15c911f4 || { echo 'GRDB privacy manifest mismatch' >&2; exit 1; }
  cp "$privacy" "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy"
  cp "$JARVIS_CONTROLLED_GRDB_PATH/LICENSE" "$app_dir/Contents/Resources/GRDB-LICENSE"
  codesign --force --deep --sign - "$app_dir" >&2
  codesign --verify --deep --strict "$app_dir" >&2
else
  resource="$bin_dir/GRDB_GRDB.bundle"
  if [ ! -d "$resource" ]; then printf 'Required GRDB resource bundle missing: %s\n' "$resource" >&2; exit 1; fi
  cp -R "$resource" "$app_dir/"
fi
printf '%s\n' "$app_dir"
