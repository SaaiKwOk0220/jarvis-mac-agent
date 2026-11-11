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
experimental=false
combined=false
if [ "${1:-}" = --combined-experiment ]; then combined=true; shift; fi
exact=false
if [ "${1:-}" = --exact-experiment ]; then exact=true; shift; fi
if [ "${1:-}" = --experimental ]; then experimental=true; shift; fi
if [[ "${1:-}" == --* ]]; then printf 'Unknown build option: %s\n' "$1" >&2; exit 2; fi
if (( $# > 1 )); then printf 'Usage: %s [--experimental] [output-dir]\n' "$0" >&2; exit 2; fi
if { "$experimental" && "$exact"; } || { "$combined" && { "$experimental" || "$exact" || [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ]; }; } || { [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ] && { "$experimental" || "$exact"; }; }; then printf 'Choose one experiment.\n' >&2; exit 1; fi
output_dir="${1:-$package_dir/.build/dev-app}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
if "$combined"; then
  swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/combined-experiment" -Xswiftc -DJARVIS_COMBINED_EXPERIMENT --product JarvisMenuBar >&2
  bin_dir="$(swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/combined-experiment" --show-bin-path)"
elif "$exact"; then
  swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/browser-experiment" -Xswiftc -DJARVIS_EXACT_BROWSER_EXPERIMENT --product JarvisMenuBar >&2
  bin_dir="$(swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/browser-experiment" --show-bin-path)"
elif "$experimental"; then
  swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/vad-experiment" -Xswiftc -DJARVIS_VAD_EXPERIMENT --product JarvisMenuBar >&2
  bin_dir="$(swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/vad-experiment" --show-bin-path)"
elif [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  swift build --package-path "$package_dir" --product JarvisMenuBar -Xswiftc -DJARVIS_SAFARI_EXPERIMENT_BUILD >&2
  bin_dir="$(swift build --package-path "$package_dir" --show-bin-path -Xswiftc -DJARVIS_SAFARI_EXPERIMENT_BUILD)"
else
  swift build --package-path "$package_dir" --product JarvisMenuBar >&2
  bin_dir="$(swift build --package-path "$package_dir" --show-bin-path)"
fi
if [ "${JARVIS_STABLE_OUTPUT:-0}" = 1 ]; then
  if [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" != 1 ]; then
    printf 'Stable output is only supported for the Safari experiment.\n' >&2
    exit 1
  fi
  stage_dir="$(mktemp -d "$output_dir/.jarvis-stage.XXXXXX")"
  trap 'rm -rf -- "$stage_dir"' EXIT
  app_dir="$stage_dir/Jarvis.app"
else
  bundle_dir="$(mktemp -d "$output_dir/Jarvis.XXXXXX")"
  app_dir="$bundle_dir/Jarvis.app"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
if "$combined"; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.combined-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisCombinedExperiment bool true' "$app_dir/Contents/Info.plist"
elif "$exact"; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.browser-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisBrowserExperiment bool true' "$app_dir/Contents/Info.plist"
elif "$experimental"; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.vad-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisExperimentalIsolation bool true' "$app_dir/Contents/Info.plist"
elif [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.safari-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Jarvis Safari Experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisSafariExperiment bool true' "$app_dir/Contents/Info.plist"
fi
cp "$bin_dir/JarvisMenuBar" "$app_dir/Contents/MacOS/JarvisMenuBar"
if [ -n "${JARVIS_CONTROLLED_GRDB_PATH:-}" ]; then
  privacy="$JARVIS_CONTROLLED_GRDB_PATH/GRDB/PrivacyInfo.xcprivacy"
  test "$(shasum -a 256 "$privacy" | cut -d ' ' -f 1)" = 17784da62e51f74c5859df32fe402e01e25cdf6f797a4add06e2a3ce15c911f4 || { echo 'GRDB privacy manifest mismatch' >&2; exit 1; }
  cp "$privacy" "$app_dir/Contents/Resources/PrivacyInfo.xcprivacy"
  cp "$JARVIS_CONTROLLED_GRDB_PATH/LICENSE" "$app_dir/Contents/Resources/GRDB-LICENSE"
else
  resource="$bin_dir/GRDB_GRDB.bundle"
  if [ ! -d "$resource" ]; then printf 'Required GRDB resource bundle missing: %s\n' "$resource" >&2; exit 1; fi
  cp -R "$resource" "$app_dir/Contents/Resources/"
fi
vad_resource="$bin_dir/Jarvis_JarvisMenuBar.bundle"
if [ ! -d "$vad_resource" ]; then printf 'Required Jarvis model resource bundle missing: %s\n' "$vad_resource" >&2; exit 1; fi
cp -R "$vad_resource" "$app_dir/Contents/Resources/"
# The copied SwiftPM executable may carry its own signature. Seal the final
# bundle after its plist and resource bundle are in their final locations.
codesign --force --deep --sign - "$app_dir" >&2
codesign --verify --deep --strict "$app_dir" >&2
if [ "${JARVIS_STABLE_OUTPUT:-0}" = 1 ]; then
  # Darwin renamex_np with RENAME_EXCL atomically refuses an existing target.
  /usr/bin/python3 - "$app_dir" "$output_dir/Jarvis.app" <<'PYRENAME'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
rename = libc.renamex_np
rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int
if rename(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), 4) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[2])
PYRENAME
  app_dir="$output_dir/Jarvis.app"
fi
printf '%s\n' "$app_dir"
