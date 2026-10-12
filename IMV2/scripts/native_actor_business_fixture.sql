INSERT INTO im_v2.public_user_profiles
  (user_id, public_handle, display_name, revision, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000012', 'g4_sender', 'G4 Sender',
        1, clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.rooms
  (room_id, room_shard_id, capacity_profile_id, capacity_class, membership_revision)
VALUES ('00000000-0000-0000-0000-000000000011', 'room-a', 'standard', 'standard', 1);
INSERT INTO im_v2.room_owner_routes
  (room_id, room_shard_id, route_epoch, created_at, updated_at)
VALUES ('00000000-0000-0000-0000-000000000011', 'room-a', 0,
        clock_timestamp(), clock_timestamp());
INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
VALUES ('00000000-0000-0000-0000-000000000011',
        '00000000-0000-0000-0000-000000000012', 'G4 room', clock_timestamp());
INSERT INTO im_v2.shard_admission_pools
  (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
VALUES ('room-a', 'standard', '00000000-0000-0000-0000-000000000014',
        1, clock_timestamp() + interval '10 minutes', 10);
INSERT INTO im_v2.room_admission
  (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
VALUES ('00000000-0000-0000-0000-000000000011', 1, 10,
        '00000000-0000-0000-0000-000000000014', 1);
INSERT INTO im_v2.room_memberships (room_id, user_id, role, joined_revision)
VALUES ('00000000-0000-0000-0000-000000000011',
        '00000000-0000-0000-0000-000000000012', 'owner', 1);
INSERT INTO im_v2.user_shard_router_configuration
  (configuration_key, router_epoch, default_write_bucket, updated_at)
VALUES (TRUE, 1, 'g4-users', clock_timestamp());
