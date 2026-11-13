import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('kokoro_runner', Path(__file__).with_name('run.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class Limits(unittest.TestCase):
    def test_text_limits(self):
        self.assertEqual(r.validate_text('你好'), '你好')
        for value in ['', '  ', 'x' * 301, 'a\x00b']:
            with self.assertRaises(ValueError): r.validate_text(value)

    def test_profile_denies_network_and_writes_outside_private_directory(self):
        profile = r.profile('/private/tmp/test-kokoro')
        self.assertIn('(deny network*)', profile)
        self.assertIn('(deny file-write*)', profile)
        self.assertIn('(subpath "/private/tmp/test-kokoro")', profile)
        with self.assertRaises(ValueError): r.profile('/tmp/evil"path')

    def test_output_limit_rejects_excess(self):
        self.assertEqual(r.append_bounded(b'abc', b'd', 4), b'abcd')
        with self.assertRaises(ValueError): r.append_bounded(b'abc', b'de', 4)

if __name__ == '__main__': unittest.main()

class FailClosed(unittest.TestCase):
    def test_invalid_inputs_do_not_start_process(self):
        from unittest.mock import patch
        with patch.object(r.sys, 'platform', 'darwin'), patch.object(r.subprocess, 'Popen') as popen:
            with self.assertRaises(ValueError): r.run('/not/a/runtime', '/not/a/model', 'test', 1)
            popen.assert_not_called()

    def test_non_macos_fails_closed(self):
        from unittest.mock import patch
        with patch.object(r.sys, 'platform', 'linux'):
            with self.assertRaises(RuntimeError): r.run('/x', '/y', 'test', 1)
