#!/bin/bash
# Validate actual experimental executable rejects mispackaging before app startup.
# Each run denies all filesystem writes, protecting the user's data.
set -euo pipefail
source_app="${1:?Pass the path to a built --experimental Jarvis.app}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

check_rejected() {
  local scenario="$1"
  local app="$tmp_dir/$scenario/Jarvis.app"
  mkdir -p "$tmp_dir/$scenario"
  cp -R "$source_app" "$app"
  case "$scenario" in
    wrong-id) /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.jarvis.dev' "$app/Contents/Info.plist" ;;
    missing-marker) /usr/libexec/PlistBuddy -c 'Delete :JarvisExperimentalIsolation' "$app/Contents/Info.plist" ;;
  esac
  local status=0
  sandbox-exec -p '(version 1) (allow default) (deny file-write*)' \
    "$app/Contents/MacOS/JarvisMenuBar" >"$tmp_dir/$scenario.out" 2>"$tmp_dir/$scenario.err" || status=$?
  if [[ "$status" -eq 0 ]] || ! grep -Fq '实验构建身份或数据隔离配置无效，已停止启动。' "$tmp_dir/$scenario.err"; then
    printf 'FAILED: %s (exit %s)\n' "$scenario" "$status" >&2
    cat "$tmp_dir/$scenario.err" >&2
    return 1
  fi
  printf 'PASS: %s rejected (exit %s; filesystem writes denied)\n' "$scenario" "$status"
}
check_rejected wrong-id
check_rejected missing-marker
