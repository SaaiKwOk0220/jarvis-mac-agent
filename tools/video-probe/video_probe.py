#!/usr/bin/env python3
"""Non-sensitive synthetic video experiment; never accepts a user's media."""
import argparse
import base64
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unicodedata

MAX_FRAME = 1024 * 1024
MAX_REPLY = 1024 * 1024


class ProbeError(Exception):
    pass


def extract_synthetic_frames():
    """Create and inspect only the bundled fixed red/blue test video."""
    with tempfile.TemporaryDirectory(prefix='jarvis-video-probe-') as directory:
        env = os.environ.copy()
        env['CLANG_MODULE_CACHE_PATH'] = str(Path(directory) / 'clang-cache')
        try:
            result = subprocess.run(['xcrun', 'swift', str(Path(__file__).with_name('synthetic_frames.swift')), directory],
                                    env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=60, check=False)
            if result.returncode:
                raise ProbeError('Synthetic video generation or frame validation failed.')
            frames = []
            for name in ('frame-0.png', 'frame-1.png'):
                with (Path(directory) / name).open('rb') as frame:
                    data = frame.read(MAX_FRAME + 1)
                if len(data) > MAX_FRAME or not data.startswith(b'\x89PNG\r\n\x1a\n'):
                    raise ProbeError('Generated frame is invalid or exceeds the size limit.')
                frames.append(data)
            return frames
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ProbeError('Cannot generate test video within the time limit.') from exc


def describe_frames(frames, model, port):
    """Send fixed synthetic frames to an explicitly trusted loopback endpoint."""
    if not model.strip() or len(model) > 256 or not 1 <= port <= 65535:
        raise ProbeError('Invalid model name or local port.')
    payload = json.dumps({'model': model, 'stream': False, 'messages': [{'role': 'user',
        'content': 'Compare the red and blue positions in these two synthetic frames.',
        'images': [base64.b64encode(frame).decode('ascii') for frame in frames]}]}).encode()
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=120)
    try:
        connection.request('POST', '/api/chat', body=payload, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        raw = response.read(MAX_REPLY + 1)
        if response.status != 200 or len(raw) > MAX_REPLY:
            raise ProbeError('Local model request failed or exceeded the reply limit.')
        try:
            result = json.loads(raw)
            content = result['message']['content']
            if result.get('done') is not True or not isinstance(content, str):
                raise ValueError('incomplete response')
            clean = ''.join(c for c in content if c == '\n' or not unicodedata.category(c).startswith('C'))
            if not clean.strip(): raise ValueError('empty response')
            return clean
        except (ValueError, KeyError, TypeError, AttributeError) as exc:
            raise ProbeError('Local model returned an invalid response.') from exc
    except (OSError, http.client.HTTPException) as exc:
        raise ProbeError('Cannot connect to the selected local service.') from exc
    finally:
        connection.close()


def run(model, port):
    if model is not None and (not model.strip() or len(model) > 256 or not 1 <= port <= 65535):
        raise ProbeError('Invalid model name or local port.')
    frames = extract_synthetic_frames()
    if len(frames) != 2 or frames[0] == frames[1]:
        raise ProbeError('Generated video frames do not differ.')
    return describe_frames(frames, model, port) if model is not None else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', help='Explicitly opt in to a trusted local Ollama model')
    parser.add_argument('--port', type=int, default=11434)
    args = parser.parse_args()
    try:
        answer = run(args.model, args.port)
        print(answer if answer is not None else 'Synthetic frame validation passed; model was not contacted.')
        return 0
    except ProbeError as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
