\set ON_ERROR_STOP on

-- Exact campaign cleanup using the HMAC-only TSV retained on the database
-- host. It cannot revoke an unrelated user/device token.
BEGIN;
CREATE TEMPORARY TABLE disposable_load_token_hmacs (
    token_hmac text PRIMARY KEY,
    user_id uuid NOT NULL,
    device_id uuid NOT NULL,
    issued_at_epoch bigint NOT NULL,
    expires_at_epoch bigint NOT NULL
) ON COMMIT DROP;

COPY disposable_load_token_hmacs FROM :'load_token_path' WITH (FORMAT csv, DELIMITER E'\t');

DELETE FROM im_v2.device_access_tokens AS token
USING disposable_load_token_hmacs AS disposable
WHERE token.token_hmac = disposable.token_hmac
  AND token.user_id = disposable.user_id
  AND token.device_id = disposable.device_id;
COMMIT;
