-- Structured rich-message metadata is canonical message state. The event
-- stream carries the same bounded representation for fan-out and snapshots.
ALTER TABLE im_v2.messages
    ADD COLUMN rich_entities JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN reply_to_message_id UUID NULL REFERENCES im_v2.messages(message_id),
    ADD CONSTRAINT messages_rich_entities_array CHECK (jsonb_typeof(rich_entities) = 'array');

CREATE INDEX messages_reply_to_message_idx
    ON im_v2.messages (reply_to_message_id)
    WHERE reply_to_message_id IS NOT NULL;
