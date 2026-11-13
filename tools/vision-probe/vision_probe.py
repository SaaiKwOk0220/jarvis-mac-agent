#!/usr/bin/env python3
"""Describe one explicitly supplied image with a local Ollama vision model."""
import argparse
import base64
import http.client
import json
import os
import stat
import sys
from pathlib import Path

MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024
MAX_QUESTION_CHARS = 8000

class ProbeError(Exception):
    """A safe, user-facing failure that excludes request and response contents."""


def read_image(path: Path) -> bytes:
    """Read a bounded PNG/JPEG, rejecting unknown file signatures."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as image:
            if not stat.S_ISREG(os.fstat(image.fileno()).st_mode):
                raise ProbeError('The selected image must be a regular file.')
            data = image.read(MAX_IMAGE_BYTES + 1)
    except OSError as exc:
        raise ProbeError('Cannot read the specified image.') from exc
    if len(data) > MAX_IMAGE_BYTES:
        raise ProbeError('Image exceeds the 10 MiB limit.')
    if not (data.startswith(b'\x89PNG\r\n\x1a\n') or data.startswith(b'\xff\xd8\xff')):
        raise ProbeError('Image must have a PNG or JPEG signature.')
    return data


def describe(path: Path, model: str, question: str, port: int) -> str:
    """Send a bounded image and question to an explicitly named loopback model."""
    if not model.strip() or not question.strip() or len(question) > MAX_QUESTION_CHARS:
        raise ProbeError('A model name and a question of at most 8000 characters are required.')
    if not 1 <= port <= 65535:
        raise ProbeError('Invalid local Ollama port.')
    data = read_image(path)
    payload = json.dumps({'model': model, 'stream': False, 'messages': [
        {'role': 'user', 'content': question, 'images': [base64.b64encode(data).decode('ascii')]}
    ]}).encode('utf-8')
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=120)
    try:
        connection.request('POST', '/api/chat', body=payload, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        body = response.read(MAX_RESPONSE_BYTES + 1)
        if response.status != 200:
            raise ProbeError(f'Local Ollama returned HTTP {response.status}; check the selected model.')
        if len(body) > MAX_RESPONSE_BYTES:
            raise ProbeError('Local Ollama response exceeds the size limit.')
        try:
            result = json.loads(body)
            content = result['message']['content']
            if result.get('done') is not True or not isinstance(content, str) or not content.strip():
                raise ValueError('invalid result')
        except (ValueError, TypeError, KeyError, AttributeError) as exc:
            raise ProbeError('Local Ollama returned an invalid response.') from exc
        return content
    except (OSError, http.client.HTTPException) as exc:
        raise ProbeError('Cannot reach local Ollama at 127.0.0.1; check that it is running.') from exc
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path, help='Path to the user-selected PNG or JPEG')
    parser.add_argument('--model', required=True, help='Explicit installed Ollama multimodal model name')
    parser.add_argument('--port', type=int, default=11434, help='Local Ollama port (default 11434)')
    args = parser.parse_args()
    question = sys.stdin.read(MAX_QUESTION_CHARS + 1)
    try:
        print(describe(args.image, args.model, question, args.port))
    except ProbeError as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
