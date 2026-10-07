-- Drain old send/recovery processes before running. Run against the current
-- schema only; the transaction refuses to discard any unmatched success.
-- Rejections are deliberately discarded. Keep a database snapshot if a binary
-- rollback to the old, incompatible receipt-table contract is required.
BEGIN;
ALTER TABLE im_v2.message_send_completions
    ADD COLUMN IF NOT EXISTS operation_fingerprint bytea CHECK (octet_length(operation_fingerprint)=32),
    ADD COLUMN IF NOT EXISTS operation_resolved_at_ms bigint CHECK (operation_resolved_at_ms>0);
LOCK TABLE im_v2.message_send_completions IN ACCESS EXCLUSIVE MODE;
DO $$
BEGIN
    IF to_regclass('im_v2.message_send_operation_receipts') IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM im_v2.message_send_operation_receipts r
            LEFT JOIN im_v2.message_send_completions c
              ON c.room_id=r.room_id AND c.sender_user_id=r.actor_user_id AND c.client_message_id=r.operation_id
            WHERE r.receipt->'outcome' ? 'accepted'
              AND (c.message_id IS NULL OR c.request_fingerprint IS DISTINCT FROM r.domain_fingerprint
                   OR r.fingerprint_version<>1
                   OR (r.receipt#>>'{outcome,accepted,_0,messageID,rawValue}')::uuid IS DISTINCT FROM c.message_id
                   OR (r.receipt#>>'{outcome,accepted,_0,roomSequence}')::bigint IS DISTINCT FROM c.room_sequence
                   OR r.receipt#>>'{resolvedAtMilliseconds}' IS NULL
                   OR (c.operation_fingerprint IS NOT NULL AND c.operation_fingerprint<>r.request_fingerprint))
        ) THEN
            RAISE EXCEPTION 'send success migration found an unmatched or conflicting receipt';
        END IF;
        ALTER TABLE im_v2.message_send_completions DISABLE TRIGGER message_send_completions_immutable;
        UPDATE im_v2.message_send_completions c
        SET operation_fingerprint=r.request_fingerprint,
            operation_resolved_at_ms=(r.receipt->>'resolvedAtMilliseconds')::bigint
        FROM im_v2.message_send_operation_receipts r
        WHERE c.room_id=r.room_id AND c.sender_user_id=r.actor_user_id AND c.client_message_id=r.operation_id
          AND r.receipt->'outcome' ? 'accepted';
        ALTER TABLE im_v2.message_send_completions ENABLE TRIGGER message_send_completions_immutable;
        DROP TABLE im_v2.message_send_operation_receipts;
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='im_v2.message_send_completions'::regclass
                   AND conname='message_send_completions_operation_metadata_check') THEN
        ALTER TABLE im_v2.message_send_completions ADD CONSTRAINT message_send_completions_operation_metadata_check
            CHECK ((operation_fingerprint IS NULL)=(operation_resolved_at_ms IS NULL));
    END IF;
END $$;
COMMIT;
