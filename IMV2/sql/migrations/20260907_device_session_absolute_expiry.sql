-- Drain credential writers before this controlled test-data migration.
-- New environments install schema.sql directly. Never extend an old device's
-- lifetime to the migration date: anchor it to its original creation time.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-25') <> 1 THEN
        RAISE EXCEPTION 'expected current-25 before device session expiry migration';
    END IF;
END $$;
ALTER TABLE im_v2.auth_devices ADD COLUMN session_expires_at timestamptz;
UPDATE im_v2.auth_devices SET session_expires_at = created_at + interval '30 days';
ALTER TABLE im_v2.auth_devices ALTER COLUMN session_expires_at SET NOT NULL;
ALTER TABLE im_v2.auth_devices ALTER COLUMN session_expires_at SET DEFAULT (CURRENT_TIMESTAMP + interval '30 days');
ALTER TABLE im_v2.auth_devices ADD CONSTRAINT auth_devices_session_expiry_finite CHECK (isfinite(session_expires_at));

UPDATE im_v2.auth_devices SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP)
WHERE session_expires_at <= CURRENT_TIMESTAMP;
UPDATE im_v2.device_access_tokens AS token SET revoked_at = COALESCE(token.revoked_at, CURRENT_TIMESTAMP)
FROM im_v2.auth_devices AS device WHERE token.device_id = device.device_id AND device.revoked_at IS NOT NULL;
UPDATE im_v2.device_refresh_sessions AS session SET revoked_at = COALESCE(session.revoked_at, CURRENT_TIMESTAMP)
FROM im_v2.auth_devices AS device WHERE session.device_id = device.device_id AND device.revoked_at IS NOT NULL;
UPDATE im_v2.push_device_endpoints AS endpoint SET disabled_at = COALESCE(endpoint.disabled_at, CURRENT_TIMESTAMP)
FROM im_v2.auth_devices AS device WHERE endpoint.device_id = device.device_id AND device.revoked_at IS NOT NULL;
INSERT INTO im_v2.device_revocation_events (user_id, device_id, created_at)
SELECT user_id, device_id, CURRENT_TIMESTAMP FROM im_v2.auth_devices WHERE revoked_at IS NOT NULL
ON CONFLICT (device_id) DO NOTHING;
UPDATE im_v2.device_access_tokens AS token SET expires_at = LEAST(token.expires_at, device.session_expires_at)
FROM im_v2.auth_devices AS device WHERE token.device_id = device.device_id AND device.revoked_at IS NULL;
UPDATE im_v2.device_refresh_sessions AS session SET expires_at = LEAST(session.expires_at, device.session_expires_at)
FROM im_v2.auth_devices AS device WHERE session.device_id = device.device_id AND device.revoked_at IS NULL;

ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-26';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-26';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-26');
COMMIT;
