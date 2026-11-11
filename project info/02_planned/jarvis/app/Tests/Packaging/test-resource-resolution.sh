#!/bin/bash
# Test the same Bundle.main lookup used by SwiftPM's GRDB resource accessor.
# The temporary probe has no build-path fallback and does not launch Jarvis.
set -euo pipefail
app_dir="${1:?Pass the path to a real built Jarvis.app}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
probe="$tmp_dir/Probe.app"
mkdir -p "$probe/Contents/MacOS" "$probe/Contents/Resources"
cp "$app_dir/Contents/Info.plist" "$probe/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Probe' "$probe/Contents/Info.plist"
cp -R "$app_dir/Contents/Resources/GRDB_GRDB.bundle" "$probe/Contents/Resources/"
cat > "$tmp_dir/probe.swift" <<'SWIFT'
import Foundation
guard let resources = Bundle.main.resourceURL else { exit(1) }
let path = resources.appendingPathComponent("GRDB_GRDB.bundle")
guard let bundle = Bundle(url: path), bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil else {
    fputs("GRDB resource bundle could not be resolved at \(path.path)\n", stderr)
    exit(1)
}
print("Resolved GRDB resources at \(path.path)")
SWIFT
swiftc "$tmp_dir/probe.swift" -o "$probe/Contents/MacOS/Probe"
"$probe/Contents/MacOS/Probe"
