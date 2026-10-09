"""Observe real provider bytes and one owned App's durable download artifacts.

Never create a grant/task/file or alter business state. Only aggregate evidence
is exported; original task identities remain private to this observation gate.
"""
from contextlib import closing
import hashlib
import sqlite3
import threading
import uuid

from v2_native_background_upload_gate import BACKGROUND_FIXTURE_BYTES


class NativeBackgroundDownloadGate:
    def __init__(self):
        self.lock = threading.Lock()
        self.release_event = threading.Event()
        self.scope = None
        self.mapping = None
        self.original_job = None
        self.original_task_identifier = None
        self.account_directory = None
        self.values = dict(hits=0, foregroundHits=0, sentBytes=0, released=False,
                           completed=0, expired=False, durableActiveMappings=0,
                           persistedBytes=0, checksumMatches=False, artifactCount=0, pendingJobs=0, responseInterrupted=False, originalIntentPreserved=False, originalTaskMappingPreserved=False, processKills=0)

    def arm(self, scope):
        with self.lock:
            if self.scope is not None:
                raise ValueError('download observation already armed')
            self.scope = str(uuid.UUID(scope))

    def claim(self, path, status, body, headers):
        if not path.startswith(('/v2/resource-bytes/', '/v2/local-media/download/')):
            return False
        with self.lock:
            if self.scope is None or status != 200 or body != BACKGROUND_FIXTURE_BYTES:
                return False
            self.values['hits'] += 1
            if headers.get('Range') is not None:
                self.values['foregroundHits'] += 1
            return self.values['hits'] == 1

    def write(self, handler, data):
        handler.wfile.write(data[:16384])
        handler.wfile.flush()
        with self.lock:
            self.values['sentBytes'] = 16384
        if not self.release_event.wait(180):
            with self.lock:
                self.values['expired'] = True
            raise TimeoutError('owned background download observation expired')
        try:
            handler.wfile.write(data[16384:])
            handler.wfile.flush()
        except OSError:
            handler.close_connection = True
            with self.lock:
                self.values['responseInterrupted'] = True
            return
        with self.lock:
            self.values['sentBytes'] = len(data)
            self.values['completed'] += 1

    def capture_durable_mapping(self, container):
        with self.lock:
            if self.mapping is not None:
                return
        root_name = 'sync-local-e2e-' + self.scope + '.sqlite.accounts'
        roots = list(container.rglob(root_name))
        if len(roots) != 1:
            raise RuntimeError('expected one owned account root')
        paths = list(roots[0].rglob('V2.sqlite'))
        if len(paths) != 1:
            raise RuntimeError('expected one owned account database')
        with closing(sqlite3.connect(paths[0].as_uri() + '?mode=ro', uri=True, timeout=3)) as db:
            rows = db.execute('''SELECT mapping_id,session_id,media_id,job_id,task_identifier FROM v2_background_download_jobs
                WHERE state='transferring' AND expected_bytes=? AND checksum=?''',
                (len(BACKGROUND_FIXTURE_BYTES), hashlib.sha256(BACKGROUND_FIXTURE_BYTES).hexdigest())).fetchall()
        with self.lock:
            self.values['durableActiveMappings'] = len(rows)
            if len(rows) == 1:
                self.mapping = (str(uuid.UUID(rows[0][0])).upper(), str(uuid.UUID(rows[0][1])).upper(), rows[0][2])
                self.original_job = rows[0][3]
                self.original_task_identifier = rows[0][4]
                self.account_directory = paths[0].parent

    def snapshot(self, container=None):
        with self.lock:
            mapping, directory = self.mapping, self.account_directory
        if container is not None and mapping is not None:
            attempt, session, media = mapping
            stage = container / 'Library/Application Support/IMV2BackgroundTransfers/downloads' / session / 'files' / attempt
            stem = hashlib.sha256(media.encode()).hexdigest()
            files = [stage] + list((directory / 'media-cache').glob(stem + '.*.media'))
            valid = []
            for path in files:
                try:
                    if path.is_file() and not path.is_symlink() and path.stat().st_size == len(BACKGROUND_FIXTURE_BYTES) and hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(BACKGROUND_FIXTURE_BYTES).digest():
                        valid.append(path)
                except FileNotFoundError:
                    # Publication atomically moves the stage into the cache.
                    # A later observation will find the same verified bytes.
                    continue
            pending = 0
            intent_preserved = task_preserved = False
            database = directory / 'V2.sqlite'
            if database.exists():
                with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=3)) as db:
                    pending = db.execute('SELECT count(*) FROM v2_background_download_jobs WHERE media_id=?', (media,)).fetchone()[0]
                    original = db.execute('SELECT mapping_id,session_id,task_identifier FROM v2_background_download_jobs WHERE job_id=?', (self.original_job,)).fetchone()
                    intent_preserved = original is not None
                    task_preserved = original is not None and original[0] == attempt and original[1] == session and original[2] == self.original_task_identifier
            with self.lock:
                self.values['originalIntentPreserved'] = intent_preserved
                self.values['originalTaskMappingPreserved'] = task_preserved
                self.values['pendingJobs'] = pending
                self.values['artifactCount'] = len(valid)
                self.values['persistedBytes'] = len(BACKGROUND_FIXTURE_BYTES) if valid else 0
                self.values['checksumMatches'] = bool(valid)
        with self.lock:
            return dict(self.values)

    def record_process_kill(self):
        with self.lock:
            self.values['processKills'] += 1

    def release(self):
        with self.lock:
            self.values['released'] = True
        self.release_event.set()
