-- Read receipts remain one monotonic watermark per room/user. These tables
-- store only disclosure policy and durable idempotency for its mutation.
CREATE TABLE im_v2.user_read_receipt_preferences (
    user_id UUID PRIMARY KEY REFERENCES im_v2.users(user_id),
    allows_direct_read_receipts BOOLEAN NOT NULL DEFAULT TRUE,
    allows_group_read_receipts BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.read_receipt_preference_operations (
    actor_user_id UUID NOT NULL REFERENCES im_v2.users(user_id),
    operation_id UUID NOT NULL,
    allows_direct_read_receipts BOOLEAN NOT NULL,
    allows_group_read_receipts BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);

-- The on-demand group detail query filters by this lookup and page-sorts by
-- update time. It never fan-outs a receipt to every group member.
CREATE INDEX room_read_receipts_detail_lookup_idx
    ON im_v2.room_read_receipts (room_id, updated_at DESC, user_id DESC);
