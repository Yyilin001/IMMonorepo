-- Contract direct message-row events to the existing per-room timeline
-- cursor. The reader version that filters `timeline_sequence` must be live
-- before this migration is applied.
--
-- PostgreSQL cannot drop an index concurrently inside a transaction. Run
-- this file through the non-transactional migration runner, as-is.

ALTER TABLE im_v2.messages
    ADD CONSTRAINT messages_message_row_sequences_match
    CHECK (
        accepted_event_storage <> 'message_row'
        OR room_sequence = timeline_sequence
    ) NOT VALID;

ALTER TABLE im_v2.messages
    VALIDATE CONSTRAINT messages_message_row_sequences_match;

DROP INDEX CONCURRENTLY IF EXISTS im_v2.messages_direct_event_cursor_idx;
