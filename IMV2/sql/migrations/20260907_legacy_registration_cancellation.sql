-- Controlled schema-29 migration. Drain all old credential writers first.
-- Never run old and new issuers together after enabling legacy cancellation.
-- Existing credentials remain valid; no historical cancellation is inferred.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-29') <> 1 THEN
        RAISE EXCEPTION 'expected current-29 before legacy registration cancellation migration';
    END IF;
END $$;

CREATE TABLE im_v2.legacy_device_registration_cancellations (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    cancelled_at timestamptz NOT NULL,
    CONSTRAINT legacy_registration_cancellation_pkey PRIMARY KEY (user_id, device_id),
    CONSTRAINT legacy_registration_cancellation_operation UNIQUE (user_id, operation_id),
    CONSTRAINT legacy_registration_cancellation_time CHECK (isfinite(cancelled_at))
);

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-30';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-30';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-30');
COMMIT;
