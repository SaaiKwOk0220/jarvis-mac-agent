#!/bin/bash
set -euo pipefail
app_dir="$(cd "$(dirname "$0")/../.." && pwd)"
source_repo="${JARVIS_GRDB_SOURCE_REPO:?Pass a local upstream GRDB git checkout}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
prepared="$("$app_dir/scripts/prepare-controlled-grdb.sh" "$source_repo" "$tmp_dir/cache")"
test -f "$prepared/LICENSE"
test "$(shasum -a 256 "$prepared/GRDB/PrivacyInfo.xcprivacy" | cut -d ' ' -f 1)" = 17784da62e51f74c5859df32fe402e01e25cdf6f797a4add06e2a3ce15c911f4
grep -q 'exclude: \["PrivacyInfo.xcprivacy"\]' "$prepared/Package.swift"
prepared_again="$("$app_dir/scripts/prepare-controlled-grdb.sh" "$source_repo" "$tmp_dir/cache")"
test "$prepared" = "$prepared_again"
printf '\n// tampered\n' >> "$prepared/GRDB/Core/Database.swift"
if "$app_dir/scripts/prepare-controlled-grdb.sh" "$source_repo" "$tmp_dir/cache" >/dev/null 2>&1; then
  echo 'tampered cache accepted' >&2; exit 1
fi

mkdir "$tmp_dir/symlink-cache"
ln -s "$prepared" "$tmp_dir/symlink-cache/GRDB.swift"
if "$app_dir/scripts/prepare-controlled-grdb.sh" "$source_repo" "$tmp_dir/symlink-cache" >/dev/null 2>&1; then
  echo 'symlink cache accepted' >&2; exit 1
fi
# An externally supplied path must not influence the repository manifest.
malicious="$tmp_dir/attacker"
mkdir -p "$malicious"
JARVIS_CONTROLLED_GRDB_PATH="$malicious" swift package --package-path "$app_dir" dump-package > "$tmp_dir/package.json"
if grep -F "$malicious" "$tmp_dir/package.json" >/dev/null; then
  echo 'untrusted GRDB path used by manifest' >&2; exit 1
fi
# A forged controlled path cannot make the ordinary build claim controlled packaging.
if JARVIS_CONTROLLED_GRDB_PATH="$malicious" JARVIS_GRDB_SOURCE_REPO="$source_repo" JARVIS_GRDB_CACHE_DIR="$tmp_dir/symlink-cache" "$app_dir/scripts/build-dev-app.sh" "$tmp_dir/forged-output" >/dev/null 2>&1; then
  echo 'forged controlled build accepted' >&2; exit 1
fi
# Even a valid source path cannot relabel an ordinary remote-dependency build.
valid_cache="$tmp_dir/valid-cache"
valid_path="$("$app_dir/scripts/prepare-controlled-grdb.sh" "$source_repo" "$valid_cache")"
if JARVIS_CONTROLLED_GRDB_PATH="$valid_path" JARVIS_GRDB_SOURCE_REPO="$source_repo" JARVIS_GRDB_CACHE_DIR="$valid_cache" "$app_dir/scripts/build-dev-app.sh" "$tmp_dir/mislabelled-output" >/dev/null 2>&1; then
  echo 'ordinary manifest accepted as controlled' >&2; exit 1
fi
