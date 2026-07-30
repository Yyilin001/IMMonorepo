-- The planner advances a durable, page-level counter together with its keyset
-- checkpoint.  It lets the final page prove target accounting without a
-- second COUNT(*) scan over every already-created delivery row.
ALTER TABLE im_v2.fanout_plans
    ADD COLUMN enumerated_target_count BIGINT NOT NULL DEFAULT 0
        CHECK (
            enumerated_target_count >= 0
            AND (target_count IS NULL OR enumerated_target_count <= target_count)
        );

-- A retained control database may contain a partially enumerated plan. Its
-- committed delivery rows are the only safe durable count to seed here; an
-- inconsistent historical plan fails the constraint instead of being silently
-- marked complete by the new terminal-page optimization.
UPDATE im_v2.fanout_plans AS plan
SET enumerated_target_count = persisted.target_count
FROM (
    SELECT source_event_id, COUNT(*)::bigint AS target_count
    FROM im_v2.fanout_deliveries
    GROUP BY source_event_id
) AS persisted
WHERE persisted.source_event_id = plan.source_event_id;
