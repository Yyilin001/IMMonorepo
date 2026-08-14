-- Protocol V17 makes low-watermark recovery lazy and shares a checkpoint
-- artifact across devices. These indexes keep the exact artifact lookup and
-- revoked-device housekeeping proportional to their bounded batches.

CREATE INDEX sync_snapshot_artifacts_reusable_idx
    ON im_v2.sync_snapshot_artifacts
       (user_id, capability_profile, schema_version,
        base_user_sync_sequence DESC, created_at DESC)
    WHERE state IN ('building', 'published')
      AND source_projected_sequence = base_user_sync_sequence;

CREATE INDEX auth_devices_revoked_cleanup_idx
    ON im_v2.auth_devices (revoked_at, user_id, device_id)
    WHERE revoked_at IS NOT NULL;
