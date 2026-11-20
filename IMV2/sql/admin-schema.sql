-- 独立管理数据，不改变 IM 协议或 im_v2 schema 版本。仅显式安装一次。
BEGIN;
CREATE SCHEMA im_admin;
CREATE TABLE im_admin.schema_version (version integer PRIMARY KEY CHECK (version = 1));
INSERT INTO im_admin.schema_version VALUES (1);
CREATE TABLE im_admin.sessions (
    digest text PRIMARY KEY CHECK (digest ~ '^[a-f0-9]{64}$'),
    username text NOT NULL,
    credential_version text NOT NULL CHECK (credential_version ~ '^[a-f0-9]{64}$'),
    expires_at timestamptz NOT NULL
);
CREATE INDEX admin_sessions_expiry ON im_admin.sessions(expires_at);
CREATE TABLE im_admin.login_budgets (
    bucket text PRIMARY KEY,
    window_started_at timestamptz NOT NULL,
    attempts integer NOT NULL CHECK (attempts > 0)
);
CREATE TABLE im_admin.audit (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    operation_id uuid NOT NULL UNIQUE,
    principal text CHECK (principal ~ '^admin:[a-z0-9._-]{3,64}$'),
    action text NOT NULL CHECK (action IN ('login','logout','users_search','user_view','account_disable')),
    target_user_id uuid,
    reason text CHECK (reason IN ('user_requested','credential_compromise','policy_enforcement')),
    outcome text NOT NULL CHECK (outcome IN ('succeeded','rejected','forbidden','pending','disabled','already_disabled')),
    occurred_at timestamptz NOT NULL,
    completed_at timestamptz,
    CHECK ((outcome = 'pending') = (completed_at IS NULL)),
    CHECK (reason IS NULL OR (action = 'account_disable' AND target_user_id IS NOT NULL AND principal IS NOT NULL))
);
CREATE INDEX admin_audit_target ON im_admin.audit(target_user_id, sequence DESC);
-- 应用只可将已登记禁用操作的 pending 状态收敛，不可改写主体、目标或既有结果。
CREATE FUNCTION im_admin.protect_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'admin audit is append only'; END IF;
    IF OLD.outcome <> 'pending' OR NEW.outcome NOT IN ('disabled','already_disabled')
       OR NEW.completed_at IS NULL
       OR ROW(NEW.sequence, NEW.operation_id, NEW.principal, NEW.action, NEW.target_user_id, NEW.reason, NEW.occurred_at)
          IS DISTINCT FROM ROW(OLD.sequence, OLD.operation_id, OLD.principal, OLD.action, OLD.target_user_id, OLD.reason, OLD.occurred_at)
    THEN RAISE EXCEPTION 'immutable admin audit identity or result'; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER protect_admin_audit BEFORE UPDATE OR DELETE ON im_admin.audit FOR EACH ROW EXECUTE FUNCTION im_admin.protect_audit();
COMMIT;
