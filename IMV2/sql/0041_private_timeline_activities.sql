-- Private conversation activity is not a message and must never consume a
-- message sequence, create a room event, or enter the fan-out pipeline.
-- Timeline sequencing is therefore independent from message sequencing.

ALTER TABLE im_v2.rooms
    ADD COLUMN timeline_sequence BIGINT NOT NULL DEFAULT 0 CHECK (timeline_sequence >= 0);
UPDATE im_v2.rooms SET timeline_sequence = room_sequence WHERE timeline_sequence = 0;

ALTER TABLE im_v2.messages
    ADD COLUMN timeline_sequence BIGINT;
UPDATE im_v2.messages SET timeline_sequence = room_sequence WHERE timeline_sequence IS NULL;
ALTER TABLE im_v2.messages
    ALTER COLUMN timeline_sequence SET NOT NULL,
    ADD CONSTRAINT messages_timeline_sequence_positive CHECK (timeline_sequence > 0),
    ADD CONSTRAINT messages_room_timeline_sequence_key UNIQUE (room_id, timeline_sequence);

CREATE TABLE im_v2.room_timeline_activities (
    source_event_id UUID PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    timeline_sequence BIGINT NOT NULL CHECK (timeline_sequence > 0),
    activity_type TEXT NOT NULL CHECK (activity_type IN ('direct_message_restricted')),
    recipient_user_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE (room_id, timeline_sequence)
);
CREATE INDEX room_timeline_activities_recipient_order_idx
    ON im_v2.room_timeline_activities (recipient_user_id, room_id, timeline_sequence);

-- A denied client message ID is terminal. Retrying the same offline command
-- replays the same private activity rather than allocating a new timeline
-- position or repeatedly exposing a policy state transition.
CREATE TABLE im_v2.direct_message_denials (
    sender_user_id UUID NOT NULL,
    client_message_id UUID NOT NULL,
    room_id UUID NOT NULL REFERENCES im_v2.rooms(room_id) ON DELETE RESTRICT,
    source_event_id UUID NOT NULL UNIQUE REFERENCES im_v2.room_timeline_activities(source_event_id) ON DELETE RESTRICT,
    timeline_sequence BIGINT NOT NULL CHECK (timeline_sequence > 0),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (sender_user_id, client_message_id),
    UNIQUE (room_id, timeline_sequence)
);
