BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-13') <> 1 THEN
        RAISE EXCEPTION 'forward receipt migration requires schema 13';
    END IF;
END $$;
-- Terminal source receipts release delivery capacity and source object pins.
-- No FK to a target message: the target is a different physical database.
CREATE TABLE im_v2.message_forward_export_receipts (
    export_id uuid PRIMARY KEY REFERENCES im_v2.message_forward_exports(export_id) ON DELETE RESTRICT,
    payload_digest bytea NOT NULL CHECK (octet_length(payload_digest) = 32),
    state text NOT NULL,
    result_message_id uuid,
    result_room_sequence bigint,
    error_code text,
    recorded_at timestamptz NOT NULL,
    CONSTRAINT message_forward_export_receipts_shape_check CHECK (
        (state = 'completed' AND result_message_id IS NOT NULL
         AND result_room_sequence IS NOT NULL AND result_room_sequence > 0 AND error_code IS NULL)
        OR (state = 'rejected' AND result_message_id IS NULL AND result_room_sequence IS NULL
            AND error_code IS NOT NULL AND octet_length(error_code) BETWEEN 1 AND 128)
    )
);
CREATE FUNCTION im_v2.reject_forward_export_receipt_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'forward export terminal receipt is immutable' USING ERRCODE = '23514';
END;
$$;
CREATE TRIGGER message_forward_export_receipts_immutable
    BEFORE UPDATE OR DELETE ON im_v2.message_forward_export_receipts FOR EACH ROW
    EXECUTE FUNCTION im_v2.reject_forward_export_receipt_mutation();

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-14';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-14';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-14');
COMMIT;
