BEGIN;

-- Keep only one hot-path body copy for new plain direct room-log events.
-- If a message later changes revision, the trigger records the old content in
-- the same transaction. Readers can therefore hydrate an immutable event
-- revision without trusting the mutable current message row.
CREATE TABLE IF NOT EXISTS im_v2.message_content_versions (
    message_id uuid NOT NULL,
    message_revision bigint NOT NULL,
    text_body text NOT NULL,
    rich_entities jsonb NOT NULL,
    archived_at timestamp with time zone NOT NULL,
    CONSTRAINT message_content_versions_pkey PRIMARY KEY (message_id, message_revision),
    CONSTRAINT message_content_versions_message_revision_check CHECK (message_revision > 0),
    CONSTRAINT message_content_versions_rich_entities_array CHECK (jsonb_typeof(rich_entities) = 'array'::text),
    CONSTRAINT message_content_versions_message_id_fkey
        FOREIGN KEY (message_id) REFERENCES im_v2.messages(message_id) ON DELETE RESTRICT
);

CREATE OR REPLACE FUNCTION im_v2.snapshot_message_content_before_revision_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.content_revision <> OLD.content_revision THEN
        INSERT INTO im_v2.message_content_versions
            (message_id, message_revision, text_body, rich_entities, archived_at)
        VALUES
            (OLD.message_id, OLD.content_revision, OLD.text_body, OLD.rich_entities, now())
        ON CONFLICT (message_id, message_revision) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS messages_snapshot_content_before_revision_change
    ON im_v2.messages;
CREATE TRIGGER messages_snapshot_content_before_revision_change
    BEFORE UPDATE OF content_revision ON im_v2.messages
    FOR EACH ROW EXECUTE FUNCTION im_v2.snapshot_message_content_before_revision_change();

COMMIT;
