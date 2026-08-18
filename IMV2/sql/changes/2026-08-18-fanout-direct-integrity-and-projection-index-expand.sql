\set ON_ERROR_STOP on

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '0';

CREATE FUNCTION im_v2.reject_fanout_plan_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
       OR NEW.target_rule IS DISTINCT FROM OLD.target_rule THEN
        RAISE EXCEPTION 'fanout plan identity and target rule are immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.reject_fresh_direct_delivery_identity_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.fresh_direct_eligible IS DISTINCT FROM OLD.fresh_direct_eligible THEN
        RAISE EXCEPTION 'fresh direct eligibility is immutable';
    END IF;
    IF OLD.fresh_direct_eligible
       AND (
           NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
           OR NEW.target_user_id IS DISTINCT FROM OLD.target_user_id
           OR NEW.projection_kind IS DISTINCT FROM OLD.projection_kind
           OR NEW.completion_unit_id IS DISTINCT FROM OLD.completion_unit_id
       ) THEN
        RAISE EXCEPTION 'fresh direct delivery identity is immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION im_v2.validate_fresh_direct_delivery_batch() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM inserted_fanout_deliveries
        WHERE fresh_direct_eligible
    ) THEN
        RETURN NULL;
    END IF;

    IF EXISTS (
        SELECT source_event_id
        FROM inserted_fanout_deliveries
        WHERE fresh_direct_eligible
        GROUP BY source_event_id
        HAVING count(*) <> 2
            OR count(DISTINCT completion_unit_id) <> 1
    ) OR EXISTS (
        SELECT 1
        FROM inserted_fanout_deliveries AS delivery
        LEFT JOIN im_v2.fanout_plans AS plan
          ON plan.source_event_id = delivery.source_event_id
        LEFT JOIN im_v2.fanout_completion_units AS unit
          ON unit.source_event_id = delivery.source_event_id
         AND unit.completion_unit_id = delivery.completion_unit_id
        WHERE delivery.fresh_direct_eligible
          AND (
              plan.source_event_id IS NULL
              OR plan.target_rule->>'planning_strategy' <> 'direct_preplanned'
              OR plan.state <> 'planned'
              OR plan.target_count <> 2
              OR plan.enumerated_target_count <> 2
              OR unit.completion_unit_id IS NULL
              OR unit.target_count <> 2
              OR unit.target_boundary->>'audience_kind' <> 'direct_preplanned'
          )
    ) THEN
        RAISE EXCEPTION 'invalid fresh direct delivery batch';
    END IF;
    RETURN NULL;
END;
$$;

ALTER TABLE im_v2.fanout_plans
    ADD CONSTRAINT fanout_plans_direct_preplanned_shape_check CHECK (
        target_rule->>'planning_strategy' IS DISTINCT FROM 'direct_preplanned'
        OR (
            state IN ('planned', 'terminal')
            AND target_count = 2
            AND enumerated_target_count = 2
            AND reserved_fanout_cost = 2
        )
    ) NOT VALID;
ALTER TABLE im_v2.fanout_plans
    VALIDATE CONSTRAINT fanout_plans_direct_preplanned_shape_check;

CREATE TRIGGER fanout_deliveries_fresh_direct_batch_validate
AFTER INSERT ON im_v2.fanout_deliveries
REFERENCING NEW TABLE AS inserted_fanout_deliveries
FOR EACH STATEMENT
EXECUTE FUNCTION im_v2.validate_fresh_direct_delivery_batch();

CREATE TRIGGER fanout_deliveries_fresh_direct_immutable
BEFORE UPDATE OF source_event_id, target_user_id, projection_kind,
    completion_unit_id, fresh_direct_eligible
ON im_v2.fanout_deliveries
FOR EACH ROW
EXECUTE FUNCTION im_v2.reject_fresh_direct_delivery_identity_mutation();

CREATE TRIGGER fanout_plans_identity_immutable
BEFORE UPDATE OF source_event_id, target_rule ON im_v2.fanout_plans
FOR EACH ROW
EXECUTE FUNCTION im_v2.reject_fanout_plan_identity_mutation();

COMMIT;

-- The primary key has the same user/kind/key/from prefix and every snapshot
-- row still visits the heap for payload/source columns. The wider index did
-- not avoid a heap read, but every version insert and close maintained it.
DROP INDEX CONCURRENTLY IF EXISTS im_v2.user_projection_versions_snapshot_scan_idx;
