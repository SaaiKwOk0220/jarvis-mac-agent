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
output="$(PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" "$app_dir/scripts/build-dev-app.sh" "$tmp_dir/output")"
test -x "$output/Contents/MacOS/JarvisMenuBar"
test -f "$output/Contents/MacOS/GRDB_GRDB.bundle/test.txt"
test ! -e "$output/Contents/MacOS/Unrelated.bundle"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$output/Contents/Info.plist")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$output/Contents/Info.plist")" = JarvisMenuBar
