#!/usr/bin/env python3
"""Experimental short-text Kokoro PCM generator; stdin text, stdout raw PCM."""
import argparse
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MAX_BYTES = 2_000_000

def validate_text(value):
    if not value.strip() or len(value) > 300 or '\0' in value:
        raise ValueError('Expected 1–300 characters without NUL')
    return value

def profile(directory):
    if (not directory.startswith('/private/tmp/') or os.path.realpath(directory) != directory
            or not os.path.isdir(directory) or any(c in directory for c in '"\\\n\r')):
        raise ValueError('Invalid sandbox path')
    return '(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n(allow file-write* (subpath "' + directory + '"))\n'

def append_bounded(current, chunk, limit=MAX_BYTES):
    if len(current) + len(chunk) > limit:
        raise ValueError('PCM limit exceeded')
    return current + chunk

def run(runtime, model, text, timeout):
    # Disabled until a verified child lifecycle mechanism can prevent leaked helpers.
    raise RuntimeError('Experiment disabled pending safe subprocess isolation')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', required=True); parser.add_argument('--model', required=True)
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args()
    try:
        if not 0 < args.timeout <= 300: raise ValueError('Invalid timeout')
        text = validate_text(sys.stdin.read(1201))
        sys.stdout.buffer.write(run(args.python, args.model, text, args.timeout))
    except (ValueError, OSError, RuntimeError, TimeoutError, KeyboardInterrupt) as error:
        print('Kokoro experiment failed:', type(error).__name__, file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
