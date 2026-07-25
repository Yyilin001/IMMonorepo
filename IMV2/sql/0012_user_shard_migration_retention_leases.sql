-- Retention cleanup is external I/O against the old logical owner. Keep a
-- short fenced lease in the control plane so an interrupted cleaner can be
-- reclaimed without permitting concurrent destructive cleanup.
ALTER TABLE im_v2.user_shard_migrations
    ADD COLUMN retention_claim_token UUID NULL,
    ADD COLUMN retention_claim_expires_at TIMESTAMPTZ NULL,
    ADD COLUMN retention_retry_count BIGINT NOT NULL DEFAULT 0 CHECK (retention_retry_count >= 0);

ALTER TABLE im_v2.user_shard_migrations
    ADD CONSTRAINT user_shard_migrations_retention_claim_shape CHECK (
        (retention_claim_token IS NULL AND retention_claim_expires_at IS NULL)
        OR
        (retention_claim_token IS NOT NULL AND retention_claim_expires_at IS NOT NULL)
    );

CREATE INDEX user_shard_migrations_retention_claim_idx
    ON im_v2.user_shard_migrations (phase, retention_until, retention_claim_expires_at)
    WHERE phase = 'retention';
