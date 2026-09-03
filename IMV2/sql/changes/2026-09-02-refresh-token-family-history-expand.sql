-- Retain only consumed refresh-token digests for the lifetime of the token
-- they represent. This lets the account service distinguish proven family
-- reuse from an attacker-controlled random mismatch without retaining
-- plaintext credentials or extending encrypted response replay storage.
--
-- `CREATE INDEX CONCURRENTLY` cannot run in a transaction. Apply this file
-- with the same non-transactional migration runner used by other expand DDL.
CREATE TABLE im_v2.device_refresh_token_history (
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    family_generation bigint NOT NULL,
    refresh_hmac text NOT NULL,
    consumed_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT device_refresh_token_history_pkey
        PRIMARY KEY (device_id, family_generation),
    CONSTRAINT device_refresh_token_history_generation_check
        CHECK (family_generation > 0),
    CONSTRAINT device_refresh_token_history_refresh_hmac_check
        CHECK (length(refresh_hmac) = 64),
    CONSTRAINT device_refresh_token_history_time_check
        CHECK (expires_at > consumed_at),
    CONSTRAINT device_refresh_token_history_user_id_device_id_fkey
        FOREIGN KEY (user_id, device_id)
        REFERENCES im_v2.auth_devices(user_id, device_id)
        ON DELETE RESTRICT
);

CREATE UNIQUE INDEX CONCURRENTLY device_refresh_token_history_device_hmac_idx
    ON im_v2.device_refresh_token_history (device_id, refresh_hmac);

CREATE INDEX CONCURRENTLY device_refresh_token_history_expiry_idx
    ON im_v2.device_refresh_token_history
        (expires_at, device_id, family_generation);

-- Update readiness only after the history table and both access paths exist.
ALTER TABLE im_v2.schema_contract
    DROP CONSTRAINT schema_contract_schema_id_check;

UPDATE im_v2.schema_contract
SET schema_id = 'im-v2-current-4'
WHERE schema_id = 'im-v2-current-3';

ALTER TABLE im_v2.schema_contract
    ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-4';

ALTER TABLE im_v2.schema_contract
    ADD CONSTRAINT schema_contract_schema_id_check
        CHECK (schema_id = 'im-v2-current-4');
