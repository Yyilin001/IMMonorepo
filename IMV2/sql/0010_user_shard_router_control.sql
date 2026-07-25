-- Logical user-shard routing is a versioned control-plane fact. It stores
-- buckets only: physical endpoints and credentials must not enter durable
-- fan-out rows or this configuration table.
CREATE TABLE im_v2.user_shard_router_configuration (
    configuration_key BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (configuration_key),
    router_epoch BIGINT NOT NULL CHECK (router_epoch >= 0),
    default_write_bucket TEXT NOT NULL CHECK (length(btrim(default_write_bucket)) > 0),
    default_read_fallback_bucket TEXT NULL CHECK (
        default_read_fallback_bucket IS NULL
        OR (length(btrim(default_read_fallback_bucket)) > 0
            AND default_read_fallback_bucket <> default_write_bucket)
    ),
    updated_at TIMESTAMPTZ NOT NULL
);

-- An override establishes exactly one current write owner for a user. The
-- optional fallback is read-only migration metadata and is never used as a
-- second fan-out target.
CREATE TABLE im_v2.user_shard_route_overrides (
    user_id UUID PRIMARY KEY,
    write_bucket TEXT NOT NULL CHECK (length(btrim(write_bucket)) > 0),
    read_fallback_bucket TEXT NULL CHECK (
        read_fallback_bucket IS NULL
        OR (length(btrim(read_fallback_bucket)) > 0
            AND read_fallback_bucket <> write_bucket)
    ),
    router_epoch BIGINT NOT NULL CHECK (router_epoch >= 0),
    updated_at TIMESTAMPTZ NOT NULL
);

-- Operation IDs make operator retries replay-safe and provide a bounded audit
-- fact without recording physical topology or user content.
CREATE TABLE im_v2.user_shard_route_operations (
    operation_id UUID PRIMARY KEY,
    operator_principal TEXT NOT NULL CHECK (length(btrim(operator_principal)) > 0),
    user_id UUID NOT NULL,
    write_bucket TEXT NOT NULL,
    read_fallback_bucket TEXT NULL,
    resulting_router_epoch BIGINT NOT NULL CHECK (resulting_router_epoch >= 0),
    created_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX user_shard_route_operations_user_idx
    ON im_v2.user_shard_route_operations (user_id, created_at DESC);
