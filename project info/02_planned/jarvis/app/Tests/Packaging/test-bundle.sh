#!/bin/bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/build/GRDB_GRDB.bundle" "$tmp_dir/build/Unrelated.bundle" "$tmp_dir/build/Jarvis_JarvisMenuBar.bundle"
printf '#!/bin/sh\nexit 0\n' > "$tmp_dir/build/JarvisMenuBar"
chmod +x "$tmp_dir/build/JarvisMenuBar"
printf 'resource' > "$tmp_dir/build/GRDB_GRDB.bundle/test.txt"
printf 'model' > "$tmp_dir/build/Jarvis_JarvisMenuBar.bundle/silero-v6.2.3.onnx"
cat > "$tmp_dir/bin/swift" <<'SWIFT'
#!/bin/sh
if [ -n "${SWIFT_ARGUMENTS_LOG:-}" ]; then printf '%s\n' "$*" >> "$SWIFT_ARGUMENTS_LOG"; fi
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

vad_output="$(PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" "$app_dir/scripts/build-dev-app.sh" --experimental "$tmp_dir/vad")"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$vad_output/Contents/Info.plist")" = local.jarvis.vad-experiment
test -f "$vad_output/Contents/Resources/Jarvis_JarvisMenuBar.bundle/silero-v6.2.3.onnx"
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 "$app_dir/scripts/build-dev-app.sh" --experimental "$tmp_dir/both" >/dev/null 2>&1; then exit 1; fi

combined_output="$(PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" SWIFT_ARGUMENTS_LOG="$tmp_dir/no-click-args" /bin/bash "$app_dir/scripts/build-dev-app.sh" --combined-experiment "$tmp_dir/combined")"
if /usr/bin/grep -q -- '-DJARVIS_SAFARI_CLICK_EXPERIMENT' "$tmp_dir/no-click-args"; then exit 1; fi
PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" SWIFT_ARGUMENTS_LOG="$tmp_dir/click-args" JARVIS_COMBINED_CLICK_EXPERIMENT=1 /bin/bash "$app_dir/scripts/build-dev-app.sh" --combined-experiment "$tmp_dir/combined-click" >/dev/null
/usr/bin/grep -q -- '-DJARVIS_SAFARI_CLICK_EXPERIMENT' "$tmp_dir/click-args"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$combined_output/Contents/Info.plist")" = local.jarvis.combined-experiment
test "$(/usr/libexec/PlistBuddy -c 'Print :JarvisCombinedExperiment' "$combined_output/Contents/Info.plist")" = true
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 "$app_dir/scripts/build-dev-app.sh" --combined-experiment "$tmp_dir/invalid-combined" >/dev/null 2>&1; then exit 1; fi

# Stable experiment output is predictable and never overwrites an existing app.
stable="$tmp_dir/stable"
output="$(PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$stable")"
test "$output" = "$stable/Jarvis.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist")" = local.jarvis.safari-experiment
printf sentinel > "$output/sentinel"
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$stable" >/dev/null 2>&1; then exit 1; fi
test "$(cat "$output/sentinel")" = sentinel

# Failed signing must remove only the newly created stable app, permitting retry.
failure="$tmp_dir/failure"
mkdir -p "$failure"
printf '#!/bin/sh\nexit 1\n' > "$tmp_dir/bin/codesign"
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$failure" >/dev/null 2>&1; then exit 1; fi
test ! -e "$failure/Jarvis.app"
printf '#!/bin/sh\nexit 0\n' > "$tmp_dir/bin/codesign"
PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$failure" >/dev/null

missing="$tmp_dir/missing"
mkdir -p "$tmp_dir/no-resource"
printf '#!/bin/sh\nexit 0\n' > "$tmp_dir/no-resource/JarvisMenuBar"
chmod +x "$tmp_dir/no-resource/JarvisMenuBar"
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/no-resource" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$missing" >/dev/null 2>&1; then exit 1; fi
test ! -e "$missing/Jarvis.app"

# Concurrent creator wins: publisher must not overwrite or delete its app.
race="$tmp_dir/race"
mkdir -p "$race"
cat > "$tmp_dir/bin/codesign" <<'RACE'
#!/bin/sh
if [ "$1" = --force ]; then mkdir -p "$RACE_DEST/Jarvis.app"; printf concurrent > "$RACE_DEST/Jarvis.app/sentinel"; fi
exit 0
RACE
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" RACE_DEST="$race" JARVIS_SAFARI_EXPERIMENT_BUNDLE=1 JARVIS_STABLE_OUTPUT=1 "$app_dir/scripts/build-dev-app.sh" "$race" >/dev/null 2>&1; then exit 1; fi
test "$(cat "$race/Jarvis.app/sentinel")" = concurrent

# Unknown options and excess arguments must fail before creating output.
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" "$app_dir/scripts/build-dev-app.sh" --unknown >/dev/null 2>&1; then exit 1; fi
if PATH="$tmp_dir/bin:$PATH" FAKE_BUILD_DIR="$tmp_dir/build" "$app_dir/scripts/build-dev-app.sh" "$tmp_dir/one" "$tmp_dir/two" >/dev/null 2>&1; then exit 1; fi
