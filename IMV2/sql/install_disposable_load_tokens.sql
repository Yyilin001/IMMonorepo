\set ON_ERROR_STOP on

-- `load_token_path` is a psql-client-local TSV produced by
-- generate_v2_disposable_load_tokens.py. The clear token never enters this
-- file or PostgreSQL; only its SHA-256 HMAC is installed.
BEGIN;
CREATE TEMPORARY TABLE disposable_load_tokens (
    token_hmac text PRIMARY KEY,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    issued_at_epoch bigint NOT NULL,
    expires_at_epoch bigint NOT NULL
) ON COMMIT DROP;

COPY disposable_load_tokens FROM :'load_token_path' WITH (FORMAT csv, DELIMITER E'\t');

INSERT INTO im_v2.device_access_tokens (
    token_hmac, user_id, device_id, issued_at, expires_at
)
SELECT token.token_hmac,
       token.user_id,
       token.device_id,
       to_timestamp(token.issued_at_epoch),
       to_timestamp(token.expires_at_epoch)
FROM disposable_load_tokens AS token
JOIN im_v2.auth_devices AS device
  ON device.user_id = token.user_id
 AND device.device_id = token.device_id
 AND device.revoked_at IS NULL;

DO $$
DECLARE installed_count bigint;
BEGIN
    SELECT count(*) INTO installed_count
    FROM im_v2.device_access_tokens AS installed
    JOIN disposable_load_tokens AS expected USING (token_hmac);
    IF installed_count <> (SELECT count(*) FROM disposable_load_tokens) THEN
        RAISE EXCEPTION 'not every disposable load token was installed';
    END IF;
END $$;
COMMIT;
