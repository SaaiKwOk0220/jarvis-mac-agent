#!/bin/bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/build/GRDB_GRDB.bundle" "$tmp_dir/build/Unrelated.bundle"
printf '#!/bin/sh\nexit 0\n' > "$tmp_dir/build/JarvisMenuBar"
chmod +x "$tmp_dir/build/JarvisMenuBar"
printf 'resource' > "$tmp_dir/build/GRDB_GRDB.bundle/test.txt"
cat > "$tmp_dir/bin/swift" <<'SWIFT'
#!/bin/sh
case "$*" in *--show-bin-path*) printf '%s\n' "$FAKE_BUILD_DIR";; esac
SWIFT
chmod +x "$tmp_dir/bin/swift"
printf '#!/bin/sh\nexit 0\n' > "$tmp_dir/bin/codesign"
chmod +x "$tmp_dir/bin/codesign"
output="$(PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" "$app_dir/scripts/build-dev-app.sh" "$tmp_dir/output")"
test -x "$output/Contents/MacOS/JarvisMenuBar"
test -f "$output/Contents/Resources/GRDB_GRDB.bundle/test.txt"
test ! -e "$output/Unrelated.bundle"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$output/Contents/Info.plist")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$output/Contents/Info.plist")" = JarvisMenuBar

# Stable experiment output is predictable and never overwrites an existing app.
stable="$tmp_dir/stable"
output="$(PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$stable")"
test "$output" = "$stable/Jarvis.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist")" = local.jarvis.safari-experiment
printf sentinel > "$output/sentinel"
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$stable" >/dev/null 2>&1; then exit 1; fi
test "$(cat "$output/sentinel")" = sentinel
