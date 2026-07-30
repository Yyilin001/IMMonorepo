-- Recovery claims frozen drafts by their quiet-period watermark. Keep this
-- separate partial index so a bounded SKIP LOCKED pass never sorts staging or
-- completed drafts as the system accumulates historical group operations.
CREATE INDEX group_room_creation_drafts_finalizing_recovery_idx
    ON im_v2.group_room_creation_drafts (updated_at)
    WHERE state = 'finalizing';
