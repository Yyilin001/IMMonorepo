BEGIN;

-- PostgreSQL executes ON UPDATE CASCADE as ordinary UPDATE statements on the
-- referencing table, so this row trigger participates in the same transaction
-- that replaces the authoritative shard lease.  No existing counters are
-- rewritten by installing the trigger; the next genuine lease replacement
-- advances the room fence and starts its new command/fanout window atomically.
CREATE OR REPLACE FUNCTION im_v2.reset_room_admission_windows_on_shard_lease_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.shard_lease_id IS DISTINCT FROM OLD.shard_lease_id
       OR NEW.shard_lease_generation IS DISTINCT FROM OLD.shard_lease_generation THEN
        NEW.command_window_used := 0;
        NEW.fanout_window_used := 0;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS room_admission_windows_follow_shard_lease
    ON im_v2.room_admission;

CREATE TRIGGER room_admission_windows_follow_shard_lease
BEFORE UPDATE OF shard_lease_id, shard_lease_generation
ON im_v2.room_admission
FOR EACH ROW
WHEN (
    NEW.shard_lease_id IS DISTINCT FROM OLD.shard_lease_id
    OR NEW.shard_lease_generation IS DISTINCT FROM OLD.shard_lease_generation
)
EXECUTE FUNCTION im_v2.reset_room_admission_windows_on_shard_lease_change();

COMMIT;
