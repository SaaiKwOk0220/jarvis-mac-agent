import unittest
from unittest.mock import patch
import json
import video_probe


class VideoProbeTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_start_model(self):
        with patch.object(video_probe, 'extract_synthetic_frames', return_value=[b'first', b'second']), \
             patch.object(video_probe, 'describe_frames', side_effect=AssertionError('network called')):
            self.assertEqual(video_probe.run(None, 11434), None)

    def test_explicit_model_sends_only_generated_frames(self):
        with patch.object(video_probe, 'extract_synthetic_frames', return_value=[b'first', b'second']), \
             patch.object(video_probe, 'describe_frames', return_value='description') as describe:
            self.assertEqual(video_probe.run('vision', 11434), 'description')
            describe.assert_called_once_with([b'first', b'second'], 'vision', 11434)

    def test_rejects_unchanged_frames(self):
        with patch.object(video_probe, 'extract_synthetic_frames', return_value=[b'same', b'same']):
            with self.assertRaises(video_probe.ProbeError): video_probe.run(None, 11434)

    def test_rejects_invalid_model_and_port_without_network(self):
        for model, port in [(' ', 11434), ('x' * 257, 11434), ('vision', 0), ('vision', 65536)]:
            with self.assertRaises(video_probe.ProbeError): video_probe.describe_frames([b'a', b'b'], model, port)

    def test_explicit_model_uses_loopback_and_rejects_redirect(self):
        class Reply:
            status = 302
            def read(self, limit): return b'{}'
        class Connection:
            def __init__(self, host, port, timeout):
                self.host, self.port = host, port
                instances.append(self)
            def request(self, method, path, body, headers):
                self.payload = json.loads(body)
            def getresponse(self): return Reply()
            def close(self): pass
        instances = []
        with patch.object(video_probe.http.client, 'HTTPConnection', Connection):
            with self.assertRaises(video_probe.ProbeError): video_probe.describe_frames([b'a', b'b'], 'vision', 11434)
        self.assertEqual((instances[0].host, instances[0].port), ('127.0.0.1', 11434))
        self.assertEqual(len(instances[0].payload['messages'][0]['images']), 2)


if __name__ == '__main__': unittest.main()
