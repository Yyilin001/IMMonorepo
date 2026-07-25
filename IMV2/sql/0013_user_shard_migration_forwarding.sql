ALTER TABLE im_v2.user_shard_migrations
    DROP CONSTRAINT user_shard_migrations_phase_check;

ALTER TABLE im_v2.user_shard_migrations
    ADD CONSTRAINT user_shard_migrations_phase_check
    CHECK (phase IN ('prepared','copying','copied','verifying','forwarding','verified','cutover','retention','completed','rolled_back','failed'));
