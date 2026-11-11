#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
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
resource="$bin_dir/GRDB_GRDB.bundle"
if [ ! -d "$resource" ]; then
  printf 'Required GRDB resource bundle missing: %s\n' "$resource" >&2
  exit 1
fi
cp -R "$resource" "$app_dir/"
vad_resource="$bin_dir/Jarvis_JarvisMenuBar.bundle"
if [ ! -d "$vad_resource" ]; then
  printf 'Required Jarvis model resource bundle missing: %s\n' "$vad_resource" >&2
  exit 1
fi
cp -R "$vad_resource" "$app_dir/"
printf '%s\n' "$app_dir"
