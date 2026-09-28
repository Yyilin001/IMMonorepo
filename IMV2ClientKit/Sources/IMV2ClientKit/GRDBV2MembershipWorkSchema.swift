import Foundation

extension GRDBV2LocalSyncStore {
    // Canonical intent + frozen command (each at most 4 KiB) and one 64 KiB
    // public receipt. Freezing exchanges this reservation in the same transaction.
    static let membershipWorkReservation:Int64=2*4_096+65_536
    static let membershipWorkSchemaSQL="""
        CREATE TABLE v2_membership_intents (
            local_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            intent_id TEXT NOT NULL UNIQUE,identity_key TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL,room_id TEXT NOT NULL,target_user_id TEXT NOT NULL,ordering_key TEXT NOT NULL,
            intent BLOB NOT NULL CHECK(length(intent)<=4096),command BLOB CHECK(length(command)<=4096),
            work_id TEXT UNIQUE REFERENCES v2_operation_work(work_id) ON DELETE RESTRICT,
            payload_bytes INTEGER NOT NULL CHECK(payload_bytes=73728),confirmation_activation_id TEXT NOT NULL,
            preparation_state TEXT NOT NULL CHECK(preparation_state IN ('ready','paused','cancelled','frozen')),
            preparation_attempts INTEGER NOT NULL DEFAULT 0 CHECK(preparation_attempts BETWEEN 0 AND 5),
            preparation_next_at REAL NOT NULL,preparation_deadline REAL,last_preparation_code TEXT,
            CHECK((work_id IS NOT NULL)=(command IS NOT NULL)),CHECK((work_id IS NOT NULL)=(preparation_state='frozen'))
        );
        CREATE INDEX v2_membership_preparation_ready ON v2_membership_intents(preparation_next_at,local_sequence) WHERE preparation_state='ready';
        CREATE INDEX v2_membership_intent_order ON v2_membership_intents(ordering_key,local_sequence);
        """
}
