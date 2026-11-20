"""Observe the current account FileStore layout without creating SDK state."""
from pathlib import Path
import hashlib
import sqlite3
import tempfile
import unittest
import uuid
from v2_native_background_upload_gate import BACKGROUND_FIXTURE_BYTES
from v2_native_background_download_gate import NativeBackgroundDownloadGate


class DownloadObservationContractTests(unittest.TestCase):
    def test_observes_owned_background_inbox_then_journal_bound_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp)
            scope = str(uuid.uuid4())
            directory = container / 'Library/Application Support' / ('sync-local-e2e-' + scope + '.sqlite.accounts') / str(uuid.uuid4())
            directory.mkdir(parents=True)
            attempt, session, media, file_id = [str(uuid.uuid4()).upper() for _ in range(4)]
            with sqlite3.connect(directory / 'V2.sqlite') as db:
                db.executescript('''CREATE TABLE v2_resource_files(file_id,storage,state,byte_count,checksum);
                    CREATE TABLE v2_resource_variants(file_id,media_id,variant_kind);
                    CREATE TABLE v2_background_download_jobs(media_id,job_id,mapping_id,session_id,task_identifier);''')
            gate = NativeBackgroundDownloadGate()
            gate.mapping = (attempt, session, media)
            gate.account_directory = directory
            stage = Path(str(directory) + '.background') / 'downloads' / session / 'files' / attempt
            stage.parent.mkdir(parents=True)
            stage.write_bytes(BACKGROUND_FIXTURE_BYTES)
            self.assertEqual(gate.snapshot(container)['artifactCount'], 1)
            stage.unlink()
            cached = container / 'Library/Caches' / ('sync-local-e2e-' + scope + '.sqlite.accounts') / directory.name / 'resources/files' / file_id
            cached.parent.mkdir(parents=True)
            cached.write_bytes(BACKGROUND_FIXTURE_BYTES)
            self.assertEqual(gate.snapshot(container)['artifactCount'], 0)
            with sqlite3.connect(directory / 'V2.sqlite') as db:
                db.execute('INSERT INTO v2_resource_files VALUES (?,?,?,?,?)', (file_id, 'cache', 'published', len(BACKGROUND_FIXTURE_BYTES), hashlib.sha256(BACKGROUND_FIXTURE_BYTES).hexdigest()))
                db.execute('INSERT INTO v2_resource_variants VALUES (?,?,?)', (file_id, media, 'original'))
            self.assertEqual(gate.snapshot(container)['artifactCount'], 1)
            self.assertTrue(gate.snapshot(container)['checksumMatches'])
            cached.write_bytes(b'corrupt')
            self.assertEqual(gate.snapshot(container)['persistedBytes'], 0)
            cached.write_bytes(BACKGROUND_FIXTURE_BYTES)
            foreground = NativeBackgroundDownloadGate()
            foreground.arm(scope, foreground=True)
            self.assertFalse(foreground.claim('/v2/resource-bytes/owned', 206, BACKGROUND_FIXTURE_BYTES, {'Range': 'bytes=0-524287'}))
            foreground.capture_published_file(container)
            observed = foreground.snapshot(container)
            self.assertEqual(observed['hits'], 1)
            self.assertEqual(observed['foregroundHits'], 1)
            self.assertEqual(observed['artifactCount'], 1)
            self.assertEqual(observed['completed'], 1)
            self.assertFalse(observed['released'])



if __name__ == '__main__':
    unittest.main()
