-- A durable shard-local fence prevents an authenticated request already in
-- flight during credential revocation from recreating cursor/capability rows
-- after asynchronous cleanup. The fact is monotonic for a device ID and is
-- copied with the user's projection during migration.

CREATE TABLE im_v2.revoked_device_projection_tombstones (
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    revoked_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (user_id, device_id)
);
