#!/bin/bash
set -euo pipefail
if [ "$#" -lt 3 ]; then echo 'Usage: with-controlled-grdb.sh <upstream-git-repo> <private-cache-directory> test|build [output-directory]' >&2; exit 2; fi
source_repo="$1"; cache="$2"; mode="$3"; shift 3
script_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
controlled="$("$script_dir/prepare-controlled-grdb.sh" "$source_repo" "$cache")"
work="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-controlled-app.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
rsync -a --exclude=.build "$app_dir/" "$work/app/"
/usr/bin/python3 - "$work/app/Package.swift" "$controlled" <<'PY'
from pathlib import Path
import json, sys
path = Path(sys.argv[1]); text = path.read_text()
old = '.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")'
if text.count(old) != 1: raise SystemExit('manifest precondition failed')
path.write_text(text.replace(old, '.package(name: "GRDB.swift", path: ' + json.dumps(sys.argv[2]) + ')'))
PY
export JARVIS_CONTROLLED_GRDB_PATH="$controlled" JARVIS_GRDB_SOURCE_REPO="$source_repo" JARVIS_GRDB_CACHE_DIR="$cache"
case "$mode" in
  test) [ "$#" -eq 0 ] || exit 2; swift test --package-path "$work/app" --scratch-path "$cache/app-build" ;;
  build) [ "$#" -eq 1 ] || exit 2; "$work/app/scripts/build-dev-app.sh" "$1" ;;
  *) echo 'Expected test or build' >&2; exit 2 ;;
esac
