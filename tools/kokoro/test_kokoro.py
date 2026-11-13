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
    def test_invalid_inputs_do_not_start_process(self):
        from unittest.mock import patch
        with patch.object(r.sys, 'platform', 'darwin'), patch.object(r.subprocess, 'Popen') as popen:
            with self.assertRaises(ValueError): r.run('/not/a/runtime', '/not/a/model', 'test', 1)
            popen.assert_not_called()

    def test_non_macos_fails_closed(self):
        from unittest.mock import patch
        with patch.object(r.sys, 'platform', 'linux'):
            with self.assertRaises(RuntimeError): r.run('/x', '/y', 'test', 1)

class ProcessCleanup(unittest.TestCase):
    def test_descendants_killed_after_leader_exit(self):
        import os, subprocess, sys, time
        for retain_stdout in (True, False):
            with self.subTest(retain_stdout=retain_stdout):
                code = ('import os,sys,time\n'
                        'pid=os.fork()\n'
                        'if pid == 0:\n'
                        ' if sys.argv[1] == "0": os.close(1)\n'
                        ' time.sleep(60)\n'
                        ' os._exit(0)\n'
                        'print(pid,flush=True)\n')
                p = subprocess.Popen([sys.executable, '-c', code, str(int(retain_stdout))],
                                     stdout=subprocess.PIPE, start_new_session=True, text=True)
                child = int(p.stdout.readline()); p.wait(timeout=5)
                try:
                    r.cleanup_process_group(p)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        try: os.kill(child, 0)
                        except ProcessLookupError: break
                        time.sleep(.02)
                    else: self.fail('descendant survived process group cleanup')
                finally:
                    try: os.kill(child, 9)
                    except ProcessLookupError: pass
                    p.stdout.close()

    def test_profile_rejects_symlink_and_outside_path(self):
        import os, tempfile
        with tempfile.TemporaryDirectory(dir='/private/tmp') as base:
            real = os.path.join(base, 'real'); os.mkdir(real)
            link = os.path.join(base, 'link'); os.symlink(real, link)
            with self.assertRaises(ValueError): r.profile(link)
            with self.assertRaises(ValueError): r.profile('/private/tmp/../etc')
