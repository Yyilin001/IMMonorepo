-- The primary key on (user_id, user_sync_sequence) already owns a B-tree
-- with exactly the same leading columns and ordering as this historical
-- index. Keeping both doubles index maintenance for every durable sync-log
-- append without improving the pull query.
DROP INDEX IF EXISTS im_v2.user_sync_log_pull_idx;
