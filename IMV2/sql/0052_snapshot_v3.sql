-- Snapshot V3: resumable, bounded-memory snapshots over a per-user
-- application-MVCC projection. This release intentionally replaces the V2
-- snapshot schema instead of supporting a rolling mixed-protocol deploy.

-- Protocol V16 lowers the reaction UTF-8 wire/storage bound. Keep the frozen
-- baseline immutable and apply the greenfield replacement at the tip.
ALTER TABLE im_v2.message_reactions
    DROP CONSTRAINT message_reactions_reaction_check;
ALTER TABLE im_v2.message_reactions
    ADD CONSTRAINT message_reactions_reaction_check
    CHECK (octet_length(reaction) > 0 AND octet_length(reaction) <= 16);

CREATE TABLE im_v2.user_projection_versions (
    user_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    entity_key TEXT NOT NULL,
    scope_room_id UUID NULL,
    valid_from_sequence BIGINT NOT NULL CHECK (valid_from_sequence > 0),
    valid_to_sequence BIGINT NULL CHECK (
        valid_to_sequence IS NULL OR valid_to_sequence > valid_from_sequence
    ),
    source_event_id UUID NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, projection_kind, entity_key, valid_from_sequence),
    CHECK (length(projection_kind) BETWEEN 1 AND 64),
    CHECK (length(entity_key) BETWEEN 1 AND 512),
    CHECK (scope_room_id IS NULL OR lower(payload->>'room_id') = scope_room_id::text)
);
CREATE UNIQUE INDEX user_projection_versions_current_idx
    ON im_v2.user_projection_versions (user_id, projection_kind, entity_key)
    WHERE valid_to_sequence IS NULL;
CREATE INDEX user_projection_versions_snapshot_scan_idx
    ON im_v2.user_projection_versions
       (user_id, projection_kind, entity_key, valid_from_sequence, valid_to_sequence);
CREATE INDEX user_projection_versions_gc_idx
    ON im_v2.user_projection_versions (valid_to_sequence, user_id)
    WHERE valid_to_sequence IS NOT NULL;
CREATE INDEX user_projection_versions_current_room_idx
    ON im_v2.user_projection_versions (user_id, scope_room_id)
    WHERE valid_to_sequence IS NULL AND scope_room_id IS NOT NULL;

-- The durable projector advances each user strictly in sequence order. Sync
-- writes only make a user eligible; they never confuse an incremental message
-- edit/reaction with a complete snapshot item.
CREATE TABLE im_v2.user_projection_checkpoints (
    user_id UUID PRIMARY KEY,
    projected_sequence BIGINT NOT NULL DEFAULT 0 CHECK (projected_sequence >= 0),
    state TEXT NOT NULL DEFAULT 'ready' CHECK (state IN ('ready', 'paused')),
    failure_count BIGINT NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
    failed_sequence BIGINT NULL CHECK (failed_sequence IS NULL OR failed_sequence > 0),
    next_attempt_at TIMESTAMPTZ NULL,
    last_failure_code TEXT NULL,
    paused_at TIMESTAMPTZ NULL,
    migration_fence_token UUID NULL,
    migration_fence_expires_at TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CHECK ((migration_fence_token IS NULL) = (migration_fence_expires_at IS NULL)),
    CHECK ((state = 'paused') = (paused_at IS NOT NULL)),
    CHECK (next_attempt_at IS NULL OR state = 'ready'),
    CHECK ((failure_count = 0) = (failed_sequence IS NULL)),
    CHECK ((failure_count = 0) = (last_failure_code IS NULL))
);
CREATE INDEX user_projection_checkpoints_claim_idx
    ON im_v2.user_projection_checkpoints (next_attempt_at, updated_at, user_id)
    WHERE state = 'ready';

-- The durable retained floor is separate from every device cursor. Future
-- devices and devices below this floor must enter through a checkpoint
-- snapshot; they can never infer a missing incremental prefix is empty.
CREATE TABLE im_v2.user_sync_retention (
    user_id UUID PRIMARY KEY,
    compacted_through_sequence BIGINT NOT NULL DEFAULT 0
        CHECK (compacted_through_sequence >= 0),
    updated_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX user_sync_retention_claim_idx
    ON im_v2.user_sync_retention (updated_at, user_id);

-- The compactor claims users by retention age, then resolves protection from
-- still-valid capabilities and the recent replay window. Without these
-- indexes one busy account turns each pass into a scan of its full capability
-- and retained-log history.
CREATE INDEX sync_tokens_compaction_protection_idx
    ON im_v2.sync_tokens (user_id, expires_at, watermark);
CREATE INDEX sync_receipts_compaction_protection_idx
    ON im_v2.sync_receipts (user_id, expires_at, first_sequence);
CREATE INDEX user_sync_log_compaction_age_idx
    ON im_v2.user_sync_log (user_id, created_at, user_sync_sequence);

-- Fan-out idempotency must remain answerable after the corresponding log row
-- is compacted. The row is inserted first and receives its sequence in the
-- same transaction as the user-visible effect.
ALTER TABLE im_v2.consumer_inbox
    ADD COLUMN user_sync_sequence BIGINT NULL
        CHECK (user_sync_sequence IS NULL OR user_sync_sequence > 0);
CREATE INDEX consumer_inbox_compaction_result_idx
    ON im_v2.consumer_inbox
       (target_user_id, user_sync_sequence, source_event_id, projection_kind)
    WHERE consumer_name = 'v2-fanout-delivery'
      AND user_sync_sequence IS NOT NULL;

-- Control-plane effects may have to be mirrored to a newly routed user shard
-- long after their incremental delivery row has been compacted. Keep one
-- immutable, small result per semantic effect instead of retaining the whole
-- ordered log as an idempotency database.
CREATE TABLE im_v2.user_projection_effects (
    user_id UUID NOT NULL,
    source_event_id UUID NOT NULL,
    projection_kind TEXT NOT NULL,
    user_sync_sequence BIGINT NOT NULL CHECK (user_sync_sequence > 0),
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, source_event_id, projection_kind),
    CHECK (length(projection_kind) BETWEEN 1 AND 64)
);
CREATE INDEX user_projection_effects_user_sequence_idx
    ON im_v2.user_projection_effects (user_id, user_sync_sequence);
CREATE INDEX user_projection_effects_direct_room_idx
    ON im_v2.user_projection_effects (user_id, (payload->>'room_id'))
    WHERE projection_kind = 'direct_room_profile';

CREATE FUNCTION im_v2.capture_user_projection_effect_v3()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.payload_storage = 'inline' AND NEW.projection_kind NOT IN
        ('message', 'membership', 'moderation', 'room') THEN
        INSERT INTO im_v2.user_projection_effects
            (user_id, source_event_id, projection_kind,
             user_sync_sequence, payload, created_at)
        VALUES (NEW.user_id, NEW.source_event_id, NEW.projection_kind,
                NEW.user_sync_sequence, NEW.payload, NEW.created_at)
        ON CONFLICT (user_id, source_event_id, projection_kind) DO UPDATE
        SET user_sync_sequence = EXCLUDED.user_sync_sequence,
            payload = EXCLUDED.payload,
            created_at = EXCLUDED.created_at
        WHERE im_v2.user_projection_effects.user_sync_sequence =
                  EXCLUDED.user_sync_sequence
          AND im_v2.user_projection_effects.payload = EXCLUDED.payload
          AND im_v2.user_projection_effects.created_at = EXCLUDED.created_at;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'conflicting immutable user projection effect';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER user_sync_log_projection_effect_v3
AFTER INSERT ON im_v2.user_sync_log
FOR EACH ROW EXECUTE FUNCTION im_v2.capture_user_projection_effect_v3();

ALTER TABLE im_v2.read_receipt_operations
    ADD COLUMN projection_recipient_user_id UUID NULL;

CREATE FUNCTION im_v2.enqueue_user_projection_v3()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO im_v2.user_projection_checkpoints (user_id, projected_sequence, updated_at)
    VALUES (NEW.user_id, 0, NEW.created_at)
    ON CONFLICT (user_id) DO UPDATE SET updated_at = LEAST(
        im_v2.user_projection_checkpoints.updated_at,
        EXCLUDED.updated_at
    );
    INSERT INTO im_v2.user_sync_retention
        (user_id, compacted_through_sequence, updated_at)
    VALUES (NEW.user_id, 0, NEW.created_at)
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER user_sync_log_snapshot_v3_projection
AFTER INSERT ON im_v2.user_sync_log
FOR EACH ROW EXECUTE FUNCTION im_v2.enqueue_user_projection_v3();

DROP TABLE im_v2.sync_snapshot_pages;
DROP TABLE im_v2.sync_snapshots;

CREATE TABLE im_v2.sync_snapshot_artifacts (
    snapshot_id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    base_user_sync_sequence BIGINT NOT NULL CHECK (base_user_sync_sequence >= 0),
    source_projected_sequence BIGINT NOT NULL CHECK (source_projected_sequence >= 0),
    schema_version INTEGER NOT NULL CHECK (schema_version > 0),
    capability_profile TEXT NOT NULL CHECK (length(capability_profile) BETWEEN 1 AND 128),
    state TEXT NOT NULL CHECK (state IN ('building', 'published', 'failed', 'expired')),
    after_projection_kind TEXT NULL,
    after_entity_key TEXT NULL,
    next_page_index INTEGER NOT NULL DEFAULT 0 CHECK (next_page_index BETWEEN 0 AND 4096),
    rolling_digest TEXT NOT NULL,
    root_digest TEXT NULL,
    page_count INTEGER NULL CHECK (page_count IS NULL OR page_count BETWEEN 0 AND 4096),
    item_count BIGINT NOT NULL DEFAULT 0 CHECK (item_count BETWEEN 0 AND 1000000),
    total_bytes BIGINT NOT NULL DEFAULT 0 CHECK (total_bytes BETWEEN 0 AND 268435456),
    lease_token UUID NULL,
    lease_expires_at TIMESTAMPTZ NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    failure_code TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    published_at TIMESTAMPTZ NULL,
    CHECK ((after_projection_kind IS NULL) = (after_entity_key IS NULL)),
    CHECK (source_projected_sequence >= base_user_sync_sequence),
    CHECK (
        (state = 'published' AND root_digest IS NOT NULL AND page_count IS NOT NULL AND published_at IS NOT NULL)
        OR state <> 'published'
    )
);
CREATE INDEX sync_snapshot_artifacts_claim_idx
    ON im_v2.sync_snapshot_artifacts (state, lease_expires_at, created_at, snapshot_id)
    WHERE state = 'building';
CREATE INDEX sync_snapshot_artifacts_cleanup_idx
    ON im_v2.sync_snapshot_artifacts (state, expires_at, snapshot_id);

CREATE TABLE im_v2.sync_snapshot_pages (
    snapshot_id UUID NOT NULL REFERENCES im_v2.sync_snapshot_artifacts(snapshot_id) ON DELETE CASCADE,
    page_index INTEGER NOT NULL CHECK (page_index BETWEEN 0 AND 4095),
    first_projection_kind TEXT NOT NULL,
    first_entity_key TEXT NOT NULL,
    last_projection_kind TEXT NOT NULL,
    last_entity_key TEXT NOT NULL,
    item_count INTEGER NOT NULL CHECK (item_count BETWEEN 1 AND 500),
    page_digest TEXT NOT NULL CHECK (length(page_digest) = 64),
    payload BYTEA NOT NULL,
    byte_count INTEGER NOT NULL CHECK (byte_count BETWEEN 1 AND 61440),
    PRIMARY KEY (snapshot_id, page_index),
    UNIQUE (snapshot_id, last_projection_kind, last_entity_key),
    CHECK ((first_projection_kind, first_entity_key) <= (last_projection_kind, last_entity_key))
);

CREATE TABLE im_v2.device_snapshot_resets (
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    reset_generation BIGINT NOT NULL CHECK (reset_generation > 0),
    snapshot_id UUID NOT NULL REFERENCES im_v2.sync_snapshot_artifacts(snapshot_id) ON DELETE RESTRICT,
    state TEXT NOT NULL CHECK (state IN ('preparing', 'ready', 'acknowledged', 'expired')),
    next_sync_token TEXT NOT NULL,
    snapshot_receipt TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    acknowledged_at TIMESTAMPTZ NULL,
    PRIMARY KEY (user_id, device_id, reset_generation),
    UNIQUE (snapshot_id, device_id, reset_generation)
);
CREATE INDEX device_snapshot_resets_snapshot_idx
    ON im_v2.device_snapshot_resets (snapshot_id, state);
CREATE INDEX device_snapshot_resets_cleanup_idx
    ON im_v2.device_snapshot_resets (state, expires_at, user_id, device_id);

ALTER TABLE im_v2.device_sync_cursors
    DROP CONSTRAINT device_sync_cursors_state_check;
ALTER TABLE im_v2.device_sync_cursors
    ADD CONSTRAINT device_sync_cursors_state_check
    CHECK (state IN ('ready', 'reset_preparing', 'reset_pending'));
ALTER TABLE im_v2.device_sync_cursors
    DROP CONSTRAINT device_sync_cursors_check;
ALTER TABLE im_v2.device_sync_cursors
    ADD CONSTRAINT device_sync_cursors_check
    CHECK (
        (state = 'ready' AND pending_snapshot_id IS NULL AND pending_base_sequence IS NULL)
        OR
        (state IN ('reset_preparing', 'reset_pending')
         AND pending_snapshot_id IS NOT NULL AND pending_base_sequence IS NOT NULL)
    );

-- A deterministic poison projection is paused after bounded retry and can be
-- replayed only through the same single-row audited operator API as the other
-- durable workers. The source event plus user pair identifies the exact
-- failed checkpoint without exposing an arbitrary sequence update.
ALTER TABLE im_v2.durable_work_replay_audit
    DROP CONSTRAINT durable_work_replay_audit_target_kind_check,
    DROP CONSTRAINT durable_work_replay_audit_target_shape_check;
ALTER TABLE im_v2.durable_work_replay_audit
    ADD CONSTRAINT durable_work_replay_audit_target_kind_check
        CHECK (target_kind IN ('room_outbox', 'fanout_delivery', 'content_review',
                              'media_scan', 'media_purge', 'read_receipt_preference_propagation',
                              'user_projection')),
    ADD CONSTRAINT durable_work_replay_audit_target_shape_check
        CHECK (
            (target_kind IN ('room_outbox', 'content_review', 'media_scan', 'media_purge')
                AND target_user_id IS NULL AND projection_kind IS NULL)
            OR (target_kind = 'fanout_delivery'
                AND target_user_id IS NOT NULL AND projection_kind IS NOT NULL)
            OR (target_kind IN ('read_receipt_preference_propagation', 'user_projection')
                AND target_user_id IS NOT NULL AND projection_kind IS NULL)
        );
ALTER TABLE im_v2.device_sync_cursors
    ADD COLUMN completed_snapshot_generation BIGINT NULL
        CHECK (completed_snapshot_generation IS NULL OR completed_snapshot_generation > 0),
    ADD COLUMN completed_snapshot_base_sequence BIGINT NULL
        CHECK (completed_snapshot_base_sequence IS NULL OR completed_snapshot_base_sequence >= 0),
    ADD CONSTRAINT device_sync_cursors_completed_snapshot_fence_check
    CHECK (
        (completed_snapshot_id IS NULL
         AND completed_snapshot_ack_receipt IS NULL
         AND completed_snapshot_generation IS NULL
         AND completed_snapshot_base_sequence IS NULL)
        OR
        (completed_snapshot_id IS NOT NULL
         AND completed_snapshot_ack_receipt IS NOT NULL
         AND completed_snapshot_generation IS NOT NULL
         AND completed_snapshot_base_sequence IS NOT NULL)
    );
