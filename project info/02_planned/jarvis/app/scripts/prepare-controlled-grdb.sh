#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then echo 'Usage: prepare-controlled-grdb.sh <upstream-git-repo> <cache-directory>' >&2; exit 2; fi
source_repo="$1"
cache="$2"
revision=b83108d10f42680d78f23fe4d4d80fc88dab3212
archive_hash=015b476733e6c34f567ef78071d2ac3b92b6249805496966856f3c7f03080e05
privacy_hash=17784da62e51f74c5859df32fe402e01e25cdf6f797a4add06e2a3ce15c911f4
mkdir -p "$cache"
cache="$(cd "$cache" && pwd)"
work="$(mktemp -d "$cache/.prepare.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
git -C "$source_repo" archive "$revision" > "$work/upstream.tar"
test "$(shasum -a 256 "$work/upstream.tar" | cut -d ' ' -f 1)" = "$archive_hash" || { echo 'GRDB archive hash mismatch' >&2; exit 1; }
mkdir "$work/expected"
tar -xf "$work/upstream.tar" -C "$work/expected"
test "$(shasum -a 256 "$work/expected/GRDB/PrivacyInfo.xcprivacy" | cut -d ' ' -f 1)" = "$privacy_hash" || { echo 'GRDB privacy manifest mismatch' >&2; exit 1; }
/usr/bin/python3 - "$work/expected/Package.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '            resources: [.copy("PrivacyInfo.xcprivacy")],'
if text.count(old) != 1:
    raise SystemExit('GRDB patch precondition failed')
path.write_text(text.replace(old, '            exclude: ["PrivacyInfo.xcprivacy"],'))
PY
if [ -L "$cache/GRDB.swift" ]; then echo 'GRDB cache must not be a symlink' >&2; exit 1; fi
if [ -e "$cache/GRDB.swift" ]; then
  /usr/bin/python3 - "$work/expected" "$cache/GRDB.swift" <<'PYCHECK'
import hashlib, os, stat, sys
from pathlib import Path
def inventory(root):
    result = {}
    for directory, names, files in os.walk(root, followlinks=False):
        for name in names + files:
            path = Path(directory) / name
            rel = str(path.relative_to(root))
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode): value = ('link', os.readlink(path))
            elif stat.S_ISREG(info.st_mode): value = ('file', hashlib.sha256(path.read_bytes()).hexdigest(), info.st_mode & 0o777)
            elif stat.S_ISDIR(info.st_mode): value = ('dir', info.st_mode & 0o777)
            else: raise SystemExit('unexpected cache file type: ' + rel)
            result[rel] = value
    return result
if inventory(Path(sys.argv[1])) != inventory(Path(sys.argv[2])):
    raise SystemExit('GRDB cache differs from verified source')
PYCHECK
else
  /usr/bin/python3 - "$work/expected" "$cache/GRDB.swift" <<'PYRENAME'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
rename = libc.renamex_np
rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int
if rename(os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2]), 4) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), sys.argv[2])
PYRENAME
fi
printf '%s\n' "$cache/GRDB.swift"
