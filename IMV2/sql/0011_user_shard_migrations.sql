CREATE TABLE im_v2.user_shard_migrations (
    migration_id UUID PRIMARY KEY,
    user_id UUID NOT NULL UNIQUE,
    source_bucket TEXT NOT NULL CHECK (length(btrim(source_bucket)) > 0),
    target_bucket TEXT NOT NULL CHECK (length(btrim(target_bucket)) > 0 AND target_bucket <> source_bucket),
    source_router_epoch BIGINT NOT NULL CHECK (source_router_epoch >= 0),
    phase TEXT NOT NULL CHECK (phase IN ('prepared','copying','copied','verifying','verified','cutover','retention','completed','rolled_back','failed')),
    source_fingerprint TEXT NULL,
    target_fingerprint TEXT NULL,
    verified_at TIMESTAMPTZ NULL,
    cutover_operation_id UUID NULL UNIQUE,
    retention_until TIMESTAMPTZ NULL,
    last_error_code TEXT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);
