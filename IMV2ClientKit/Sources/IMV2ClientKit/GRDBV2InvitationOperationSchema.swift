import Foundation

extension GRDBV2LocalSyncStore {
    // Canonical intent + frozen command (each at most 8 KiB) and one 68 KiB
    // public receipt. Freezing exchanges this reservation in the same transaction.
    static let invitationWorkReservation:Int64=2*8_192+65_536
    static let invitationWorkSchemaSQL="""
        CREATE TABLE v2_invitation_operation_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE,identity_key TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL,room_id TEXT NOT NULL,ordering_key TEXT NOT NULL,
            intent BLOB NOT NULL CHECK(length(intent)<=8192),command BLOB CHECK(length(command)<=8192),
            work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes=81920),confirmation_activation_id TEXT NOT NULL,secret_reference TEXT,secret_release_pending INTEGER NOT NULL DEFAULT 0 CHECK(secret_release_pending IN (0,1)),
            preparation_state TEXT NOT NULL CHECK(preparation_state IN ('ready','paused','cancelled','frozen')),
            preparation_attempts INTEGER NOT NULL DEFAULT 0 CHECK(preparation_attempts BETWEEN 0 AND 5),
            preparation_next_at REAL NOT NULL,preparation_deadline REAL,last_preparation_code TEXT,
            CHECK(command IS NULL OR work_id IS NOT NULL),CHECK((work_id IS NOT NULL)=(preparation_state='frozen'))
        );
        CREATE INDEX v2_invitation_preparation_ready ON v2_invitation_operation_intents(preparation_next_at,local_sequence) WHERE preparation_state='ready';
        CREATE INDEX v2_invitation_intent_order ON v2_invitation_operation_intents(ordering_key,local_sequence);
        """
}
