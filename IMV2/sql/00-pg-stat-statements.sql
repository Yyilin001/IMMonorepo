-- Operational query/WAL profiling. The extension exposes only aggregate,
-- normalized statement statistics and is not part of the im_v2 data model.
-- PostgreSQL must also start with shared_preload_libraries=pg_stat_statements.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
