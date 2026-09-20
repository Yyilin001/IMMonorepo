-- Stop account issuers before applying. Restart all services on the new code.
-- Legacy unversioned assertions are deliberately rejected. Users retry login.
BEGIN;
LOCK TABLE im_v2.schema_contract IN ACCESS EXCLUSIVE MODE;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-35') THEN
    RAISE EXCEPTION 'Expected im-v2-current-35';
  END IF;
END $$;
ALTER TABLE im_v2.account_password_credentials
  ADD COLUMN credential_revision bigint NOT NULL DEFAULT 1 CHECK (credential_revision > 0),
  ADD COLUMN recovery_code_hmac text CHECK (recovery_code_hmac IS NULL OR length(recovery_code_hmac) = 64);
ALTER TABLE im_v2.account_password_authentication_audit DROP CONSTRAINT account_password_authentication_audit_outcome_check;
ALTER TABLE im_v2.account_password_authentication_audit ADD CONSTRAINT account_password_authentication_audit_outcome_check
  CHECK (outcome = ANY (ARRAY['registration_succeeded', 'assertion_succeeded', 'assertion_rejected', 'recovery_code_changed', 'password_changed', 'password_recovered']::text[]));
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-36';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-36';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-36');
COMMIT;
