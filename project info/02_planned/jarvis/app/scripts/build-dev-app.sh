#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
experimental=false
if [[ "${1:-}" == "--experimental" ]]; then
  experimental=true
  shift
fi
if [[ "${1:-}" == --* ]]; then printf 'Unknown build option: %s\n' "$1" >&2; exit 2; fi
if (( $# > 1 )); then printf 'Usage: %s [--experimental] [output-dir]\n' "$0" >&2; exit 2; fi
output_dir="${1:-$package_dir/.build/dev-app}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
if "$experimental"; then
  swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/vad-experiment" -Xswiftc -DJARVIS_VAD_EXPERIMENT --product JarvisMenuBar >&2
  bin_dir="$(swift build --package-path "$package_dir" --scratch-path "$package_dir/.build/vad-experiment" --show-bin-path)"
else
  swift build --package-path "$package_dir" --product JarvisMenuBar >&2
  bin_dir="$(swift build --package-path "$package_dir" --show-bin-path)"
fi
bundle_dir="$(mktemp -d "$output_dir/Jarvis.XXXXXX")"
app_dir="$bundle_dir/Jarvis.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$script_dir/Info.plist" "$app_dir/Contents/Info.plist"
if "$experimental"; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.vad-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisExperimentalIsolation bool true' "$app_dir/Contents/Info.plist"
fi
cp "$bin_dir/JarvisMenuBar" "$app_dir/Contents/MacOS/JarvisMenuBar"
resource="$bin_dir/GRDB_GRDB.bundle"
if [ ! -d "$resource" ]; then
  printf 'Required GRDB resource bundle missing: %s\n' "$resource" >&2
  exit 1
fi
cp -R "$resource" "$app_dir/Contents/Resources/"
vad_resource="$bin_dir/Jarvis_JarvisMenuBar.bundle"
if [ ! -d "$vad_resource" ]; then
  printf 'Required Jarvis model resource bundle missing: %s\n' "$vad_resource" >&2
  exit 1
fi
cp -R "$vad_resource" "$app_dir/Contents/Resources/"
if "$experimental"; then
  codesign --force --deep --sign - "$app_dir" >&2
  codesign --verify --deep --strict "$app_dir"
fi
printf '%s\n' "$app_dir"
