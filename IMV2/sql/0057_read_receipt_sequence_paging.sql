-- Reader enumeration is selective by the target message sequence. Ordering by
-- the same monotonic watermark lets PostgreSQL seek directly into qualifying
-- receipts for a recent/sparsely-read message instead of scanning the room's
-- entire update-time order and filtering afterwards.

DROP INDEX im_v2.room_read_receipts_detail_lookup_idx;

CREATE INDEX room_read_receipts_sequence_page_idx
    ON im_v2.room_read_receipts
       (room_id, read_through_room_sequence DESC, user_id DESC);
