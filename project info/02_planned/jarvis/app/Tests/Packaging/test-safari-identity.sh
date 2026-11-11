#!/bin/bash
set -euo pipefail
source_app="${1:?Pass built Safari experiment app}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
for scenario in wrong-id missing-marker; do
  mkdir -p "$tmp_dir/$scenario"
  app="$tmp_dir/$scenario/Jarvis.app"
  cp -R "$source_app" "$app"
  if [ "$scenario" = wrong-id ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.dev' "$app/Contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c 'Delete :JarvisSafariExperiment' "$app/Contents/Info.plist"
  fi
  status=0
  sandbox-exec -p '(version 1) (allow default) (deny file-write*)' "$app/Contents/MacOS/JarvisMenuBar" >"$tmp_dir/out" 2>"$tmp_dir/err" || status=$?
  if [ "$status" -eq 0 ] || ! grep -Fq 'Invalid experimental bundle identity.' "$tmp_dir/err"; then
    printf 'FAIL %s (exit %s)\n' "$scenario" "$status" >&2; cat "$tmp_dir/err" >&2; exit 1
  fi
  printf 'PASS %s rejected with writes denied\n' "$scenario"
done
