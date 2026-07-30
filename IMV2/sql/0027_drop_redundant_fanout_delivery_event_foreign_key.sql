-- `(source_event_id, completion_unit_id)` already references a completion
-- unit with the same source event, and every completion unit references that
-- source room event. The direct single-column FK is therefore transitively
-- guaranteed and merely adds one parent lookup per delivery insert.
ALTER TABLE im_v2.fanout_deliveries
    DROP CONSTRAINT IF EXISTS fanout_deliveries_source_event_id_fkey;
