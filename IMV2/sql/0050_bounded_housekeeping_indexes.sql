-- Expiry and terminal-state cleanup runs in small SKIP LOCKED batches. These
-- indexes keep every candidate lookup proportional to the batch rather than
-- to years of retained capabilities or completed durable work.
CREATE INDEX sync_tokens_expiry_idx ON im_v2.sync_tokens (expires_at, token);
CREATE INDEX sync_receipts_expiry_idx ON im_v2.sync_receipts (expires_at, receipt);
CREATE INDEX sync_snapshots_cleanup_idx
    ON im_v2.sync_snapshots (state, expires_at, snapshot_id);

CREATE INDEX media_scan_outbox_completed_cleanup_idx
    ON im_v2.media_scan_outbox (completed_at, media_id) WHERE state = 'completed';
CREATE INDEX media_purge_outbox_completed_cleanup_idx
    ON im_v2.media_purge_outbox (completed_at, media_id) WHERE state = 'completed';
CREATE INDEX content_review_jobs_completed_cleanup_idx
    ON im_v2.content_review_jobs (completed_at, message_id)
    WHERE state IN ('completed', 'superseded');
CREATE INDEX public_profile_update_outbox_completed_cleanup_idx
    ON im_v2.public_profile_update_outbox (completed_at, source_event_id)
    WHERE state = 'completed';
CREATE INDEX push_wake_outbox_terminal_cleanup_idx
    ON im_v2.push_wake_outbox (created_at, dispatch_id)
    WHERE state IN ('sent', 'suppressed');

CREATE INDEX fanout_plans_terminal_cleanup_idx
    ON im_v2.fanout_plans (terminal_at, source_event_id) WHERE state = 'terminal';
CREATE INDEX fanout_deliveries_terminal_source_idx
    ON im_v2.fanout_deliveries (source_event_id, target_user_id, projection_kind)
    WHERE state = 'terminal';
CREATE INDEX consumer_inbox_source_event_idx
    ON im_v2.consumer_inbox (source_event_id, consumer_name, target_user_id, projection_kind);
CREATE INDEX fanout_completion_units_released_cleanup_idx
    ON im_v2.fanout_completion_units (released_at, source_event_id, completion_unit_id)
    WHERE state = 'released';
