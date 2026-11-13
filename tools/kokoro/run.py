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
    if not directory.startswith('/private/tmp/') or any(c in directory for c in '"\\\n\r'):
        raise ValueError('Invalid sandbox path')
    return '(version 1)\n(allow default)\n(deny network*)\n(deny file-write*)\n(allow file-write* (subpath "' + directory + '"))\n'

def append_bounded(current, chunk, limit=MAX_BYTES):
    if len(current) + len(chunk) > limit:
        raise ValueError('PCM limit exceeded')
    return current + chunk

def run(runtime, model, text, timeout):
    if sys.platform != 'darwin' or not Path('/usr/bin/sandbox-exec').is_file():
        raise RuntimeError('macOS sandbox unavailable')
    if not Path(runtime).is_file() or not Path(model).is_dir():
        raise ValueError('Runtime or model not found')
    worker = str(Path(__file__).resolve().with_name('worker.py'))
    with tempfile.TemporaryDirectory(prefix='jarvis-kokoro-', dir='/private/tmp') as temp:
        os.chmod(temp, 0o700)
        sandbox = Path(temp, 'profile.sb'); sandbox.write_text(profile(temp))
        env = {'TMPDIR': temp, 'HOME': temp, 'HF_HOME': temp, 'HF_HUB_OFFLINE': '1',
               'TRANSFORMERS_OFFLINE': '1', 'PYTHONDONTWRITEBYTECODE': '1', 'PATH': '/usr/bin:/bin'}
        proc = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(sandbox), runtime, '-B', worker, model],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=env, start_new_session=True)
        try:
            proc.stdin.write(text.encode('utf-8')); proc.stdin.close()
            selector = selectors.DefaultSelector(); selector.register(proc.stdout, selectors.EVENT_READ)
            result = b''; deadline = time.monotonic() + timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise TimeoutError('Synthesis timed out')
                if not selector.select(remaining): raise TimeoutError('Synthesis timed out')
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk: break
                result = append_bounded(result, chunk)
            if proc.wait(timeout=max(0.01, deadline-time.monotonic())) != 0 or not result:
                raise RuntimeError('Synthesis failed')
            return result
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()

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
