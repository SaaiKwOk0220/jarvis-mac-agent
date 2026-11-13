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
        import tempfile
        with tempfile.TemporaryDirectory(dir='/private/tmp') as directory:
            profile = r.profile(directory)
            self.assertIn('(deny network*)', profile)
            self.assertIn('(deny file-write*)', profile)
            self.assertIn('(subpath "' + directory + '")', profile)
        with self.assertRaises(ValueError): r.profile('/tmp/evil"path')

    def test_output_limit_rejects_excess(self):
        self.assertEqual(r.append_bounded(b'abc', b'd', 4), b'abcd')
        with self.assertRaises(ValueError): r.append_bounded(b'abc', b'de', 4)

if __name__ == '__main__': unittest.main()

class FailClosed(unittest.TestCase):
    def test_disabled_runner_never_spawns_a_process(self):
        from unittest.mock import patch
        with patch.object(r.subprocess, 'Popen') as popen:
            with self.assertRaises(RuntimeError): r.run('/any/runtime', '/any/model', 'test', 1)
            popen.assert_not_called()

    def test_profile_rejects_symlink_and_outside_path(self):
        import os, tempfile
        with tempfile.TemporaryDirectory(dir='/private/tmp') as base:
            real = os.path.join(base, 'real'); os.mkdir(real)
            link = os.path.join(base, 'link'); os.symlink(real, link)
            with self.assertRaises(ValueError): r.profile(link)
            with self.assertRaises(ValueError): r.profile('/private/tmp/../etc')
