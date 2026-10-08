"""Bounded, process-local observation gate for an owned App upload test.

Only counters leave this gate. The signed provider URL and authorization
claims stay private; the real provider still validates and persists the PUT.
"""
import base64
from contextlib import closing
import hashlib
import json
import sqlite3
import threading
import urllib.parse
import uuid


BACKGROUND_FIXTURE_BYTES = (b"IMV2 native background upload acceptance\n" * 14000)[:512 * 1024]


class NativeBackgroundUploadGate:
    def __init__(self):
        self.lock = threading.Lock()
        self.release_event = threading.Event()
        self.media_id = None
        self.part_number = None
        self.values = dict(hits=0, backgroundRequests=0, foregroundHits=0, readBytes=0, released=False,
                           completed=0, status=0, checksumMatches=False, expired=False,
                           durableActiveMappings=0)

    def snapshot(self):
        with self.lock:
            return dict(self.values)

    def claim(self, target_url, byte_count):
        # Decode only for observation. This does not confer authorization: the
        # request is subsequently forwarded intact to the actual provider.
        try:
            token = urllib.parse.parse_qs(urllib.parse.urlsplit(target_url).query)['target'][0]
            encoded = token.split('.')[1]
            claims = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
            background = bool(claims.get('backgroundAuthorization'))
            # The target's mediaID names an immutable *part* object. SQLite
            # journals the original resource ID from the delegated grant.
            grant = claims['backgroundAuthorization'] if background else None
            media_id = str(uuid.UUID(grant['mediaID']['rawValue'])) if grant else None
            part_number = int(grant['partNumber']) if grant else None
        except (KeyError, IndexError, ValueError, TypeError, AttributeError):
            background = False
        with self.lock:
            if not background:
                self.values['foregroundHits'] += 1
                return False
            self.values['backgroundRequests'] += 1
            if self.values['hits'] or byte_count != len(BACKGROUND_FIXTURE_BYTES):
                return False
            self.values['hits'] = 1
            self.media_id = media_id
            self.part_number = part_number
            return True

    def capture_durable_mapping(self, container):
        # Only inspect this upload's opaque media ID. Never read credentials,
        # request payloads, source paths, session secrets, or message bodies.
        count = 0
        for path in container.rglob('*.sqlite'):
            with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=2)) as connection:
                if not connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='v2_background_transfer_tasks'").fetchone():
                    continue
                count += connection.execute('''SELECT count(*) FROM v2_background_transfer_tasks b
                    JOIN v2_resource_transfer_jobs j USING(job_id)
                    WHERE upper(j.media_id)=upper(?) AND b.state='active'
                    AND b.part_number=? AND b.expected_bytes=? AND j.next_action='awaitingBackground' ''',
                    (self.media_id, self.part_number, len(BACKGROUND_FIXTURE_BYTES))).fetchone()[0]
        with self.lock:
            self.values['durableActiveMappings'] = count

    def read(self, handler, length):
        prefix = handler.rfile.read(min(length, 16384))
        with self.lock:
            self.values['readBytes'] = len(prefix)
        if not self.release_event.wait(180):
            with self.lock:
                self.values['expired'] = True
            raise TimeoutError('owned background upload observation expired')
        body = prefix + handler.rfile.read(length - len(prefix))
        if len(body) != length:
            raise IOError('owned background upload body was incomplete')
        with self.lock:
            self.values['readBytes'] = len(body)
            self.values['checksumMatches'] = hashlib.sha256(body).digest() == hashlib.sha256(BACKGROUND_FIXTURE_BYTES).digest()
        return body

    def release(self):
        with self.lock:
            self.values['released'] = True
        self.release_event.set()

    def completed(self, status):
        with self.lock:
            self.values['status'] = status
            self.values['completed'] += 1
