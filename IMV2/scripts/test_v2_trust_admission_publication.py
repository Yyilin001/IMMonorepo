from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

from publish_v2_trust_admission import publish


class TrustAdmissionPublicationTests(unittest.TestCase):
    def test_concurrent_retry_is_durable_and_has_one_complete_file(self):
        with tempfile.TemporaryDirectory() as directory:
            data = bytes(range(256)) * 1000
            with ThreadPoolExecutor(max_workers=4) as workers:
                receipts = list(workers.map(lambda _: publish(data, directory), range(8)))
            self.assertEqual(sum(r['status'] == 'published' for r in receipts), 1)
            self.assertTrue(all(r['runtimeAcceptance'] == 'unconfirmed' for r in receipts))
            paths = list(Path(directory).iterdir())
            self.assertEqual(len(paths), 1)
            self.assertEqual(paths[0].read_bytes(), data)
            self.assertEqual(paths[0].stat().st_mode & 0o777, 0o600)

    def test_conflicting_file_and_symlink_are_not_overwritten(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / (hashlib.sha256(b'grant').hexdigest() + '.pb')
                original = root / 'original'
                original.write_bytes(b'unchanged')
                if symlink:
                    target.symlink_to(original)
                else:
                    target.write_bytes(b'unchanged')
                with self.assertRaises(subprocess.CalledProcessError):
                    publish(b'grant', directory)
                self.assertEqual(target.read_bytes(), b'unchanged')
                self.assertEqual(original.read_bytes(), b'unchanged')
                self.assertFalse(list(root.glob('*.tmp')))

    def test_invalid_target_or_packet_is_rejected_before_remote_execution(self):
        for data, directory, profile in [(b'', '/tmp', None), (b'x' * 524289, '/tmp', None),
                                         (b'x', 'relative', None), (b'x', '/tmp', 'default')]:
            with self.subTest(profile=profile, directory=directory, size=len(data)):
                with self.assertRaises(ValueError):
                    publish(data, directory, profile)


if __name__ == '__main__':
    unittest.main()
