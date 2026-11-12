#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
package_dir="$(cd "$script_dir/.." && pwd)"
output_dir="${1:-$package_dir/.build/dev-app}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
if [ "${JARVIS_SAFARI_CLICK_EXPERIMENT_BUNDLE:-0}" = 1 ] && [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  printf 'Choose only one Safari experiment bundle.\n' >&2
  exit 1
fi
build_flags=()
if [ "${JARVIS_SAFARI_CLICK_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  build_flags=(-Xswiftc -DJARVIS_SAFARI_EXPERIMENT_BUILD -Xswiftc -DJARVIS_SAFARI_CLICK_EXPERIMENT)
elif [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  build_flags=(-Xswiftc -DJARVIS_SAFARI_EXPERIMENT_BUILD)
fi
scratch_flags=()
if [ -n "${JARVIS_SWIFT_SCRATCH_PATH:-}" ]; then
  scratch_flags=(--scratch-path "$JARVIS_SWIFT_SCRATCH_PATH")
fi
if [ "${JARVIS_SWIFT_DISABLE_SANDBOX:-0}" = 1 ]; then
  scratch_flags+=(--disable-sandbox)
fi
swift build --package-path "$package_dir" "${scratch_flags[@]}" --product JarvisMenuBar "${build_flags[@]}" >&2
bin_dir="$(swift build --package-path "$package_dir" "${scratch_flags[@]}" --show-bin-path "${build_flags[@]}")"
if [ "${JARVIS_STABLE_OUTPUT:-0}" = 1 ]; then
  if [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" != 1 ] && [ "${JARVIS_SAFARI_CLICK_EXPERIMENT_BUNDLE:-0}" != 1 ]; then
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
if [ "${JARVIS_SAFARI_CLICK_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.safari-click-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Jarvis Safari Click Experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisSafariExperiment bool true' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisSafariClickExperiment bool true' "$app_dir/Contents/Info.plist"
elif [ "${JARVIS_SAFARI_EXPERIMENT_BUNDLE:-0}" = 1 ]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.safari-experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Jarvis Safari Experiment' "$app_dir/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JarvisSafariExperiment bool true' "$app_dir/Contents/Info.plist"
fi
cp "$bin_dir/JarvisMenuBar" "$app_dir/Contents/MacOS/JarvisMenuBar"
resource="$bin_dir/GRDB_GRDB.bundle"
if [ ! -d "$resource" ]; then
  printf 'Required GRDB resource bundle missing: %s\n' "$resource" >&2
  exit 1
fi
cp -R "$resource" "$app_dir/Contents/Resources/"
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
