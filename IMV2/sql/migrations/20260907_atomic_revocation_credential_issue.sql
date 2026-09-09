-- Controlled development migration: drain all credential writers first.
-- Old issued sessions lack an atomically delivered revoke-only credential.
-- Retire those sessions; do not invent a plaintext value or preserve partial
-- credential records. Uncredentialed precreated devices may still be issued.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-27') <> 1 THEN
        RAISE EXCEPTION 'expected current-27 before atomic revocation credential issue migration';
    END IF;
END $$;
UPDATE im_v2.auth_devices AS device SET revoked_at = COALESCE(device.revoked_at, CURRENT_TIMESTAMP)
WHERE EXISTS (SELECT 1 FROM im_v2.device_refresh_sessions AS session WHERE session.device_id = device.device_id)
   OR EXISTS (SELECT 1 FROM im_v2.device_access_tokens AS token WHERE token.device_id = device.device_id)
   OR EXISTS (SELECT 1 FROM im_v2.device_credential_operations AS operation WHERE operation.device_id = device.device_id);
UPDATE im_v2.device_access_tokens AS token SET revoked_at = COALESCE(token.revoked_at, CURRENT_TIMESTAMP)
FROM im_v2.auth_devices AS device WHERE token.device_id = device.device_id AND device.revoked_at IS NOT NULL;
UPDATE im_v2.device_refresh_sessions AS session SET revoked_at = COALESCE(session.revoked_at, CURRENT_TIMESTAMP)
FROM im_v2.auth_devices AS device WHERE session.device_id = device.device_id AND device.revoked_at IS NOT NULL;
UPDATE im_v2.push_device_endpoints AS endpoint SET disabled_at = COALESCE(endpoint.disabled_at, CURRENT_TIMESTAMP)
FROM im_v2.auth_devices AS device WHERE endpoint.device_id = device.device_id AND device.revoked_at IS NOT NULL;
INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
SELECT user_id, device_id, CURRENT_TIMESTAMP FROM im_v2.auth_devices WHERE revoked_at IS NOT NULL
ON CONFLICT (device_id) DO NOTHING;
DELETE FROM im_v2.device_credential_operations;

ALTER TABLE im_v2.device_credential_operations ADD COLUMN encrypted_revocation_credential text NOT NULL;
ALTER TABLE im_v2.device_credential_operations ADD COLUMN revocation_credential_expires_at timestamptz NOT NULL;
ALTER TABLE im_v2.device_credential_operations ADD CONSTRAINT device_credential_operations_revocation_result_check
    CHECK (encrypted_revocation_credential <> '' AND isfinite(revocation_credential_expires_at));
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-28';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-28';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-28');
COMMIT;
