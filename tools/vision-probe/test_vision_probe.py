import base64
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import vision_probe

PNG = b'\x89PNG\r\n\x1a\n' + b'fixture'

class Response:
    status = 200
    def __init__(self, body): self.body = body
    def read(self, limit): return self.body[:limit]

class Connection:
    last = None
    def __init__(self, host, port, timeout):
        self.host, self.port, self.timeout = host, port, timeout
        Connection.last = self
    def request(self, method, path, body, headers): self.requested = (method, path, json.loads(body), headers)
    def getresponse(self): return Response(b'{"message":{"content":"a red circle"},"done":true}')
    def close(self): pass

class ProbeTests(unittest.TestCase):
    def test_local_png_is_submitted_only_to_fixed_loopback(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'input.png'; path.write_bytes(PNG)
            with patch.object(vision_probe.http.client, 'HTTPConnection', Connection):
                answer = vision_probe.describe(path, 'vision-model', 'Describe it', 11434)
            c = Connection.last
            self.assertEqual((c.host, c.port), ('127.0.0.1', 11434))
            self.assertEqual(c.requested[0:2], ('POST', '/api/chat'))
            payload = c.requested[2]
            self.assertEqual(payload['model'], 'vision-model')
            self.assertEqual(base64.b64decode(payload['messages'][0]['images'][0]), PNG)
            self.assertEqual(answer, 'a red circle')

    def test_rejects_invalid_type_empty_and_oversized_before_network(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(vision_probe.http.client, 'HTTPConnection', side_effect=AssertionError('network called')):
            path = Path(temp) / 'file'
            for data in (b'', b'GIF89a', PNG + b'x' * vision_probe.MAX_IMAGE_BYTES):
                path.write_bytes(data)
                with self.assertRaises(vision_probe.ProbeError): vision_probe.describe(path, 'm', 'q', 11434)

    def test_fails_closed_on_redirect_and_malformed_response(self):
        class Redirect(Connection):
            def getresponse(self):
                response = Response(b'{}'); response.status = 302; return response
        class Malformed(Connection):
            def getresponse(self): return Response(b'not json')
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a'; path.write_bytes(PNG)
            for connection in (Redirect, Malformed):
                with patch.object(vision_probe.http.client, 'HTTPConnection', connection), self.assertRaises(vision_probe.ProbeError):
                    vision_probe.describe(path, 'm', 'q', 11434)

    def test_rejects_directories_and_accepts_jpeg_signature(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(vision_probe.ProbeError): vision_probe.read_image(Path(temp))
            path = Path(temp) / 'a'; path.write_bytes(b'\xff\xd8\xffjpeg')
            self.assertEqual(vision_probe.read_image(path), b'\xff\xd8\xffjpeg')

    def test_real_loopback_http_roundtrip(self):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.server.payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                result = b'{"message":{"content":"fixture answer"},"done":true}'
                self.send_response(200); self.send_header('Content-Length', str(len(result))); self.end_headers(); self.wfile.write(result)
            def log_message(self, *args): pass
        try: server = HTTPServer(('127.0.0.1', 0), Handler)
        except PermissionError: self.skipTest('sandbox disallows loopback listening')
        thread = threading.Thread(target=server.handle_request, daemon=True); thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / 'a'; path.write_bytes(PNG)
                self.assertEqual(vision_probe.describe(path, 'fixture-model', 'question', server.server_port), 'fixture answer')
                self.assertEqual(server.payload['model'], 'fixture-model')
        finally:
            thread.join(timeout=2); server.server_close()

    def test_fifo_is_rejected_without_blocking(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'pipe'; os.mkfifo(path)
            script = "import sys; from pathlib import Path; import vision_probe; vision_probe.read_image(Path(sys.argv[1]))"
            result = subprocess.run([sys.executable, '-c', script, str(path)], cwd=Path(__file__).parent, capture_output=True, timeout=1)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'ProbeError', result.stderr)

    def test_response_removes_terminal_controls_preserving_newlines(self):
        class Untrusted(Connection):
            def getresponse(self):
                body = {'message': {'content': 'safe\x1b[31mred\x1b[0m\nnext\x1b]0;title\x07end\x00\u202e'}, 'done': True}
                return Response(json.dumps(body).encode())
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a'; path.write_bytes(PNG)
            with patch.object(vision_probe.http.client, 'HTTPConnection', Untrusted):
                self.assertEqual(vision_probe.describe(path, 'm', 'q', 11434), 'safered\nnextend')

    def test_model_name_limit_is_enforced_before_network(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(vision_probe.http.client, 'HTTPConnection', side_effect=AssertionError('network called')):
            path = Path(temp) / 'a'; path.write_bytes(PNG)
            with self.assertRaises(vision_probe.ProbeError):
                vision_probe.describe(path, 'm' * 257, 'q', 11434)

    def test_control_only_response_is_rejected(self):
        class Controls(Connection):
            def getresponse(self):
                return Response(json.dumps({'message': {'content': '\u001b[31m\u0000'}, 'done': True}).encode())
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a'; path.write_bytes(PNG)
            with patch.object(vision_probe.http.client, 'HTTPConnection', Controls), self.assertRaises(vision_probe.ProbeError):
                vision_probe.describe(path, 'm', 'q', 11434)

    def test_rejects_bad_model_question_and_port(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'a'; path.write_bytes(PNG)
            for model, prompt, port in (('', 'q', 11434), ('m', '', 11434), ('m', 'q', 0), ('m', 'q', 65536)):
                with self.assertRaises(vision_probe.ProbeError): vision_probe.describe(path, model, prompt, port)

if __name__ == '__main__': unittest.main()
