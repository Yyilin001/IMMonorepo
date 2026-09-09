-- Drain old invitation writers while backfilling control. Existing links on
-- independent owners require an explicit binding import before routed rollout.
BEGIN;
DO $$ BEGIN
    IF (SELECT count(*) FROM im_v2.schema_contract WHERE schema_id = 'im-v2-current-21') <> 1 THEN
        RAISE EXCEPTION 'expected current-21 before invite directory migration';
    END IF;
END $$;
CREATE TABLE im_v2.group_invite_directory (
    actor_user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    invite_id uuid NOT NULL,
    room_id uuid NOT NULL,
    token_digest bytea NOT NULL,
    requested_lifetime_seconds bigint NOT NULL,
    maximum_approved_uses bigint NOT NULL,
    created_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    state text NOT NULL,
    ready_at timestamptz,
    CONSTRAINT group_invite_directory_pkey PRIMARY KEY (actor_user_id, operation_id),
    CONSTRAINT group_invite_directory_token_key UNIQUE (token_digest),
    CONSTRAINT group_invite_directory_invite_key UNIQUE (invite_id),
    CONSTRAINT group_invite_directory_digest_check CHECK (octet_length(token_digest) = 32),
    CONSTRAINT group_invite_directory_lifetime_check CHECK (requested_lifetime_seconds > 0),
    CONSTRAINT group_invite_directory_uses_check CHECK (maximum_approved_uses > 0),
    CONSTRAINT group_invite_directory_expiry_check CHECK (expires_at > created_at),
    CONSTRAINT group_invite_directory_state_check CHECK (state IN ('prepared', 'ready')),
    CONSTRAINT group_invite_directory_ready_check CHECK ((state = 'ready') = (ready_at IS NOT NULL))
);

CREATE FUNCTION im_v2.reject_group_invite_directory_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'invite directory bindings cannot be deleted';
    END IF;
    IF (to_jsonb(NEW) - 'state' - 'ready_at') IS DISTINCT FROM (to_jsonb(OLD) - 'state' - 'ready_at')
       OR OLD.state = 'ready'
       OR NEW.state <> 'ready' THEN
        RAISE EXCEPTION 'invite directory permits only prepared to ready';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER group_invite_directory_immutable BEFORE UPDATE OR DELETE ON im_v2.group_invite_directory
    FOR EACH ROW EXECUTE FUNCTION im_v2.reject_group_invite_directory_mutation();
-- Colocated legacy links are already committed, including expired/revoked links
-- whose requests still need deterministic lookup. Conflicting bindings abort.
INSERT INTO im_v2.group_invite_directory
    (actor_user_id, operation_id, invite_id, room_id, token_digest,
     requested_lifetime_seconds, maximum_approved_uses, created_at, expires_at, state, ready_at)
SELECT created_by_user_id, creation_operation_id, invite_id, room_id, token_digest,
       requested_lifetime_seconds, maximum_approved_uses, created_at, expires_at, 'ready', created_at
FROM im_v2.group_invite_links;
ALTER TABLE im_v2.schema_contract DROP CONSTRAINT schema_contract_schema_id_check;
ALTER TABLE im_v2.schema_contract ALTER COLUMN schema_id SET DEFAULT 'im-v2-current-22';
UPDATE im_v2.schema_contract SET schema_id = 'im-v2-current-22';
ALTER TABLE im_v2.schema_contract ADD CONSTRAINT schema_contract_schema_id_check CHECK (schema_id = 'im-v2-current-22');
COMMIT;
