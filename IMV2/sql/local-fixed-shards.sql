-- Run only during initial creation of the local PostgreSQL cluster.
\set ON_ERROR_STOP on

CREATE DATABASE imv2_rooms_primary;
\connect imv2_rooms_primary
\ir 01-schema.sql
\ir 02-realtime-change-journal.sql
SELECT source_id FROM im_v2.realtime_journal_source_identity WHERE singleton \gset
\connect im_v2
INSERT INTO im_v2.deployment_shard_sources VALUES ('rooms-primary', :'source_id');

CREATE DATABASE imv2_rooms_01;
\connect imv2_rooms_01
\ir 01-schema.sql
\ir 02-realtime-change-journal.sql
SELECT source_id FROM im_v2.realtime_journal_source_identity WHERE singleton \gset
\connect im_v2
INSERT INTO im_v2.deployment_shard_sources VALUES ('rooms-01', :'source_id');

CREATE DATABASE imv2_users_primary;
\connect imv2_users_primary
\ir 01-schema.sql
\ir 02-realtime-change-journal.sql
SELECT source_id FROM im_v2.realtime_journal_source_identity WHERE singleton \gset
\connect im_v2
INSERT INTO im_v2.deployment_shard_sources VALUES ('user:users-primary', :'source_id');

CREATE DATABASE imv2_users_01;
\connect imv2_users_01
\ir 01-schema.sql
\ir 02-realtime-change-journal.sql
SELECT source_id FROM im_v2.realtime_journal_source_identity WHERE singleton \gset
\connect im_v2
INSERT INTO im_v2.deployment_shard_sources VALUES ('user:users-01', :'source_id');
INSERT INTO im_v2.user_shard_router_configuration (router_epoch, default_write_bucket, fixed_buckets, updated_at)
VALUES (1, 'users-primary', ARRAY['users-01','users-primary'], clock_timestamp());
