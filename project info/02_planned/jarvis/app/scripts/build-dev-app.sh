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
if [ -d "$resource" ]; then
  cp -R "$resource" "$app_dir/Contents/MacOS/"
fi
printf '%s\n' "$app_dir"
