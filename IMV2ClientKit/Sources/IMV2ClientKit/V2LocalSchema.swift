import Foundation

/// 全新设备本地 V2 投影数据库的规范 schema。
///
/// 该应用尚未发布，数据库直接创建当前完整结构，不执行历史布局升级。
/// 当前版本重启时继续使用原数据库，保留待处理命令及已提交的投影效果。
extension GRDBV2LocalSyncStore {
    static let pinnedMessageProjectionSchemaSQL = """
        CREATE TABLE v2_group_pinned_messages (
            room_id TEXT NOT NULL, message_id TEXT NOT NULL,
            is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
            room_sequence INTEGER NULL CHECK (room_sequence > 0), updated_at REAL NOT NULL,
            source_event_id TEXT NULL, canonical_digest BLOB NULL CHECK (length(canonical_digest) = 32),
            CHECK ((source_event_id IS NULL) = (canonical_digest IS NULL)),
            PRIMARY KEY (room_id, message_id)
        )
        """
    static let pinnedMessageEffectsSchemaSQL = """
        CREATE TABLE v2_pin_effects (
            source_event_id TEXT NOT NULL, room_id TEXT NOT NULL, message_id TEXT NOT NULL,
            room_sequence INTEGER NULL CHECK (room_sequence > 0),
            canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
            PRIMARY KEY (source_event_id, room_id)
        )
        """

    static let announcementProjectionSchemaSQL = """
        CREATE TABLE v2_group_announcements (
            room_id TEXT PRIMARY KEY, body TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision > 0),
            room_sequence INTEGER NULL CHECK (room_sequence > 0), updated_at REAL NOT NULL,
            source_event_id TEXT NULL,
            canonical_digest BLOB NULL CHECK (length(canonical_digest) = 32),
            CHECK ((source_event_id IS NULL) = (canonical_digest IS NULL))
        )
        """
    static let announcementEffectsSchemaSQL = """
        CREATE TABLE v2_announcement_effects (
            source_event_id TEXT NOT NULL, room_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision > 0),
            room_sequence INTEGER NULL CHECK (room_sequence > 0),
            canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
            PRIMARY KEY (source_event_id, room_id)
        )
        """

    static let rolePolicyProjectionSchemaSQL = """
        CREATE TABLE v2_group_role_policies (
            room_id TEXT NOT NULL, role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
            permissions BLOB NOT NULL, revision INTEGER NOT NULL CHECK (revision > 0),
            room_sequence INTEGER NULL CHECK (room_sequence > 0),
            source_event_id TEXT NULL, canonical_digest BLOB NULL CHECK (length(canonical_digest) = 32),
            CHECK ((source_event_id IS NULL) = (canonical_digest IS NULL)),
            PRIMARY KEY (room_id, role)
        )
        """
    static let rolePolicyEffectsSchemaSQL = """
        CREATE TABLE v2_role_policy_effects (
            source_event_id TEXT NOT NULL, room_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
            revision INTEGER NOT NULL CHECK (revision > 0),
            room_sequence INTEGER NULL CHECK (room_sequence > 0),
            canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
            PRIMARY KEY (source_event_id, room_id)
        )
        """

    static let rolePolicyBaselineSchemaSQL = """
        CREATE TABLE v2_group_role_policy_baselines (
            room_id TEXT PRIMARY KEY,
            permission_revision INTEGER NOT NULL CHECK (permission_revision > 0),
            membership_revision INTEGER NOT NULL CHECK (membership_revision >= 0),
            room_sequence INTEGER NOT NULL CHECK (room_sequence >= 0),
            admin_permissions BLOB NOT NULL, member_permissions BLOB NOT NULL
        )
        """
    static let rolePolicyRecoverySchemaSQL = """
        CREATE TABLE v2_role_policy_recovery_requests (
            room_id TEXT PRIMARY KEY, request_id TEXT NOT NULL,
            installation_binding TEXT NOT NULL, user_id TEXT NOT NULL,
            membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
            membership_source_event_id TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 2147483647),
            next_attempt_at REAL NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'paused'))
        );
        CREATE INDEX v2_role_policy_recovery_due_idx ON v2_role_policy_recovery_requests (next_attempt_at, room_id) WHERE state = 'pending'
        """

    static let pushIntentSchemaSQL = """
        CREATE TABLE v2_push_intent (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            device_id TEXT NOT NULL CHECK (length(device_id) = 36),
            owner_id TEXT NOT NULL CHECK (length(owner_id) = 36),
            preference_enabled INTEGER NOT NULL CHECK (preference_enabled IN (0, 1)),
            desired_enabled INTEGER NOT NULL CHECK (desired_enabled IN (0, 1)),
            intent_revision INTEGER NOT NULL CHECK (typeof(intent_revision) = 'integer' AND intent_revision > 0),
            acknowledged_revision INTEGER NOT NULL CHECK (typeof(acknowledged_revision) = 'integer' AND acknowledged_revision >= 0 AND acknowledged_revision <= intent_revision),
            token_reference TEXT NULL CHECK (length(token_reference) = 36),
            claim_id TEXT NULL CHECK (length(claim_id) = 36),
            expected_epoch INTEGER NULL CHECK (expected_epoch IS NULL OR (typeof(expected_epoch) = 'integer' AND expected_epoch >= 0 AND expected_epoch < 9223372036854775807)),
            session_epoch INTEGER NULL CHECK (session_epoch IS NULL OR (typeof(session_epoch) = 'integer' AND session_epoch > 0)),
            attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0 AND attempt_count <= 2147483647),
            next_attempt_at REAL NOT NULL CHECK (next_attempt_at >= 0 AND next_attempt_at < 1e300),
            pause_reason TEXT NULL CHECK (pause_reason IN ('staleSession', 'conflictingIntent', 'authorization')),
            CHECK ((claim_id IS NULL) = (expected_epoch IS NULL)),
            CHECK (session_epoch IS NULL OR (expected_epoch IS NOT NULL AND session_epoch = expected_epoch + 1)),
            CHECK (token_reference IS NULL OR desired_enabled = 1)
        )
        """

    static let currentSchemaSQL = """
        CREATE VIRTUAL TABLE v2_contact_profile_search USING fts5(
                display_unigrams,
                display_bigrams,
                handle_unigrams,
                handle_bigrams,
                tokenize = 'ascii',
                detail = full,
                columnsize = 0
            );

        CREATE TABLE v2_conversation_list_entries (
                room_id TEXT PRIMARY KEY,
                last_activity REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
                is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
                mute_until REAL NOT NULL DEFAULT 0 CHECK (mute_until >= 0)
            );

        CREATE TABLE v2_conversation_states (
            room_id TEXT PRIMARY KEY,
            is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
            is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
            mute_until REAL NOT NULL CHECK (mute_until >= 0),
            updated_at REAL NOT NULL
        );

        CREATE TABLE v2_conversation_summaries (
                room_id TEXT PRIMARY KEY,
                message_id TEXT NOT NULL UNIQUE
            );

        CREATE TABLE v2_direct_read_receipt_projections (
                room_id TEXT PRIMARY KEY,
                reader_user_id TEXT NOT NULL,
                read_through_room_sequence INTEGER NOT NULL CHECK (read_through_room_sequence >= 0),
                recorded_at REAL NOT NULL,
                is_visible INTEGER NOT NULL CHECK (is_visible IN (0, 1)),
                reader_preference_revision INTEGER NOT NULL CHECK (reader_preference_revision >= 0),
                viewer_preference_revision INTEGER NOT NULL CHECK (viewer_preference_revision >= 0),
                CHECK (is_visible = 1 OR read_through_room_sequence = 0)
            );

        CREATE TABLE v2_room_read_watermarks (
                room_id TEXT PRIMARY KEY,
                read_through_room_sequence INTEGER NOT NULL CHECK (read_through_room_sequence > 0),
                recorded_at REAL NOT NULL
            );

        CREATE TABLE v2_direct_room_identities (
            room_id TEXT PRIMARY KEY,
            target_user_id TEXT NOT NULL,
            public_handle TEXT NOT NULL CHECK (length(public_handle) BETWEEN 3 AND 32),
            display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
            account_kind TEXT NOT NULL CHECK (account_kind IN ('regular', 'system', 'customer_support')),
            updated_at REAL NOT NULL,
            room_created_at REAL NOT NULL CHECK (room_created_at >= 0)
        );

        CREATE TABLE v2_direct_room_profile_projections (
            room_id TEXT PRIMARY KEY,
            source_event_id TEXT NOT NULL UNIQUE,
            target_user_id TEXT NOT NULL,
            public_handle TEXT NOT NULL CHECK (length(public_handle) BETWEEN 3 AND 32),
            display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 80),
            revision INTEGER NOT NULL CHECK (revision > 0),
            account_kind TEXT NOT NULL CHECK (account_kind IN ('regular', 'system', 'customer_support')),
            updated_at REAL NOT NULL,
            room_created_at REAL NOT NULL CHECK (room_created_at >= 0)
        );

        CREATE TABLE v2_direct_sending_capabilities (room_id TEXT PRIMARY KEY, can_send INTEGER NOT NULL CHECK (can_send IN (0, 1)), state_version INTEGER NOT NULL CHECK (state_version > 0), updated_at REAL NOT NULL);

        CREATE TABLE v2_forward_message_chunks (
                operation_id TEXT PRIMARY KEY,
                plan_id TEXT NOT NULL REFERENCES v2_forward_message_plans(plan_id),
                chunk_index INTEGER NOT NULL CHECK (chunk_index >= 0),
                source_message_ids TEXT NOT NULL, source_references TEXT,
                target_room_id TEXT NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('pending','acknowledged','rejected','cancelled')),
                completion_digest TEXT,
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                terminal_code TEXT,
                created_at REAL NOT NULL,
                UNIQUE (plan_id, chunk_index)
            );

        CREATE TABLE v2_forward_message_plans (
                plan_id TEXT PRIMARY KEY,
                source_message_ids TEXT NOT NULL, source_references TEXT,
                target_room_ids TEXT NOT NULL,
                next_chunk_index INTEGER NOT NULL CHECK (next_chunk_index >= 0),
                total_chunk_count INTEGER NOT NULL CHECK (total_chunk_count > 0),
                succeeded_count INTEGER NOT NULL DEFAULT 0 CHECK (succeeded_count >= 0),
                failed_count INTEGER NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
                state TEXT NOT NULL CHECK (state IN ('active','completed','cancelled')), terminal_code TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

        \(announcementProjectionSchemaSQL);

        \(announcementEffectsSchemaSQL);

        CREATE TABLE v2_group_event_cursors (
                room_id TEXT PRIMARY KEY,
                applied_room_sequence INTEGER NOT NULL CHECK (applied_room_sequence >= 0),
                -- 服务端已裁剪的历史下界：本地游标低于它时该房间的历史不完整，
                -- 界面必须显式告知，而不是静默地少几条。零表示从未裁剪。
                log_trimmed_through_room_sequence INTEGER NOT NULL DEFAULT 0
                    CHECK (log_trimmed_through_room_sequence >= 0),
                -- 该房间是否已确认缺过历史。缺口是永久的（服务端已经删了那段），
                -- 因此标记一旦置位就保持置位，界面据此明确告知而不是假装完整。
                history_incomplete INTEGER NOT NULL DEFAULT 0 CHECK (history_incomplete IN (0, 1))
            );

        -- A rejected cursor pull must be remembered for direct rooms too.
        -- Their profile remains useful for rendering history, but is not an
        -- authorization grant for another network read.
        CREATE TABLE v2_room_event_authorizations (
                room_id TEXT PRIMARY KEY,
                is_authorized INTEGER NOT NULL CHECK (is_authorized IN (0, 1))
            );

        CREATE TABLE v2_group_events (
                room_id TEXT NOT NULL,
                room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                source_event_id TEXT NOT NULL UNIQUE,
                projection_kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY (room_id, room_sequence)
            );

        CREATE TABLE v2_member_effects (
                source_event_id TEXT PRIMARY KEY NOT NULL,
                room_id TEXT NOT NULL, user_id TEXT NOT NULL,
                membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
                action TEXT NOT NULL CHECK (action IN ('add', 'remove', 'role')),
                role TEXT CHECK (role IN ('admin', 'member')),
                room_sequence INTEGER CHECK (room_sequence > 0),
                projection_sequence INTEGER NOT NULL CHECK (projection_sequence > 0),
                canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
                CHECK ((action = 'role' AND role IS NOT NULL) OR (action <> 'role' AND role IS NULL)),
                UNIQUE (room_id, user_id, membership_revision)
            );

        CREATE TABLE v2_group_member_roles (
                room_id TEXT NOT NULL, user_id TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
                membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
                room_sequence INTEGER NOT NULL CHECK (room_sequence > 0), PRIMARY KEY (room_id, user_id)
            );

        CREATE TABLE v2_group_permission_revisions (room_id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK (revision > 0));

        \(pinnedMessageProjectionSchemaSQL);

        \(pinnedMessageEffectsSchemaSQL);

        \(rolePolicyProjectionSchemaSQL);

        \(rolePolicyEffectsSchemaSQL);

        \(rolePolicyBaselineSchemaSQL);

        \(rolePolicyRecoverySchemaSQL);
        \(pushIntentSchemaSQL);
        \(roomRecoverySchemaSQL)
        \(roomLatestVisibleSchemaSQL)

        CREATE TABLE v2_local_installation (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                binding TEXT NOT NULL,
                user_id TEXT NULL
            );

        CREATE TABLE v2_message_favorites (
            message_id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            is_favorited INTEGER NOT NULL CHECK (is_favorited IN (0, 1)),
            updated_at REAL NOT NULL
        );

        CREATE TABLE v2_message_projections (
            message_id TEXT PRIMARY KEY,
            source_event_id TEXT NOT NULL UNIQUE,
            room_id TEXT NOT NULL,
            room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
            message_revision INTEGER NOT NULL CHECK (message_revision > 0),
            sender_user_id TEXT NOT NULL,
            text_body TEXT NOT NULL,
            media_ids TEXT NOT NULL DEFAULT '[]',
            server_created_at REAL NOT NULL,
            is_withdrawn INTEGER NOT NULL DEFAULT 0 CHECK (is_withdrawn IN (0, 1)), mention_targets TEXT NOT NULL DEFAULT '[]', media_presentations TEXT NOT NULL DEFAULT '[]', entities TEXT NOT NULL DEFAULT '[]', reply_to_message_id TEXT, forwarded_from_message_id TEXT, forwarded_from_user_id TEXT, timeline_sequence INTEGER NOT NULL DEFAULT 0,
            UNIQUE (room_id, room_sequence)
        );

        CREATE TABLE v2_sync_rebuild_requests (singleton INTEGER PRIMARY KEY CHECK (singleton = 1));

        CREATE TABLE v2_reaction_versions (
            message_id TEXT NOT NULL, room_id TEXT NOT NULL, actor_user_id TEXT NOT NULL,
            reaction TEXT NOT NULL, room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
            source_event_id TEXT NOT NULL, action TEXT NOT NULL CHECK (action IN ('add','remove')),
            canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
            PRIMARY KEY (message_id, actor_user_id, reaction)
        );
        CREATE TABLE v2_reaction_effects (
            source_event_id TEXT NOT NULL, message_id TEXT NOT NULL, room_id TEXT NOT NULL,
            actor_user_id TEXT NOT NULL, reaction TEXT NOT NULL,
            room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
            canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
            PRIMARY KEY (source_event_id, message_id, actor_user_id, reaction)
        );

        CREATE TABLE v2_message_reactions (
                message_id TEXT NOT NULL,
                room_id TEXT NOT NULL,
                actor_user_id TEXT NOT NULL,
                reaction TEXT NOT NULL CHECK (
                    length(CAST(reaction AS BLOB)) BETWEEN 1 AND 16
                ),
                PRIMARY KEY (message_id, actor_user_id, reaction)
            );

        CREATE TABLE v2_message_search_jobs (
                message_id TEXT PRIMARY KEY,
                expected_message_revision INTEGER NOT NULL CHECK (expected_message_revision > 0),
                generation INTEGER NOT NULL CHECK (generation > 0),
                enqueued_at REAL NOT NULL
            );

        CREATE TABLE v2_message_search_state (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            index_version INTEGER NOT NULL CHECK (index_version > 0),
            state TEXT NOT NULL CHECK (state IN ('building', 'ready', 'failed')),
            generation INTEGER NOT NULL CHECK (generation > 0)
        );

        CREATE TABLE v2_message_effects (
            source_event_id TEXT NOT NULL,
            projection_kind TEXT NOT NULL CHECK (projection_kind = 'message'),
            entity_key TEXT NOT NULL,
            room_id TEXT NOT NULL,
            message_revision INTEGER NOT NULL CHECK (message_revision > 0),
            canonical_digest BLOB NOT NULL CHECK (length(canonical_digest) = 32),
            PRIMARY KEY (source_event_id, projection_kind, entity_key)
        );

        CREATE TABLE v2_message_tombstones (
                message_id TEXT PRIMARY KEY,
                source_event_id TEXT NOT NULL UNIQUE,
                room_id TEXT NOT NULL,
                message_revision INTEGER NOT NULL CHECK (message_revision > 1)
            );

        CREATE TABLE v2_moderation_projections (
            source_event_id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
            actor_user_id TEXT NOT NULL,
            target_user_id TEXT NOT NULL,
            mute_until REAL NOT NULL,
            server_created_at REAL NOT NULL,
            CHECK (mute_until > server_created_at)
        );

        CREATE TABLE v2_pending_conversation_states (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                is_pinned INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
                is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
                mute_until REAL NOT NULL CHECK (mute_until >= 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                terminal_code TEXT, terminal_at REAL NULL,
                CHECK ((state = 'pending' AND terminal_code IS NULL) OR (state = 'acknowledged' AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
            );

        CREATE TABLE v2_pending_forward_messages (operation_id TEXT PRIMARY KEY, source_message_ids TEXT NOT NULL, source_references TEXT, target_room_ids TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending','acknowledged','rejected')), attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL, terminal_code TEXT, terminal_at REAL NULL);

        CREATE TABLE v2_pending_group_capabilities (
                operation_id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('pin', 'announcement', 'rolePermissions', 'memberRole')),
                room_id TEXT NOT NULL, message_id TEXT, is_pinned INTEGER CHECK (is_pinned IN (0, 1)), body TEXT,
                role TEXT CHECK (role IN ('owner', 'admin', 'member')), permissions TEXT NOT NULL,
                target_user_id TEXT, expected_revision INTEGER NOT NULL CHECK (expected_revision >= 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
                terminal_code TEXT, terminal_at REAL NULL,
                CHECK ((state = 'pending' AND terminal_code IS NULL) OR (state = 'acknowledged' AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
            );

        CREATE TABLE v2_pending_group_room_creations (
                operation_id TEXT PRIMARY KEY, title TEXT NOT NULL,
                initial_member_user_ids TEXT NOT NULL,
                capacity_class TEXT NOT NULL CHECK (capacity_class IN ('standard', 'large')),
                uploaded_member_count INTEGER NOT NULL DEFAULT 0 CHECK (uploaded_member_count >= 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'cancelling', 'finalizing', 'cancelled', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
                created_room_id TEXT,
                terminal_code TEXT, terminal_at REAL NULL,
                CHECK ((state IN ('pending', 'cancelling', 'finalizing', 'cancelled') AND created_room_id IS NULL AND terminal_code IS NULL)
                    OR (state = 'acknowledged' AND created_room_id IS NOT NULL AND terminal_code IS NULL)
                    OR (state = 'rejected' AND created_room_id IS NULL AND terminal_code IS NOT NULL))
            );

        CREATE TABLE v2_pending_member_mutes (
            operation_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, target_user_id TEXT NOT NULL,
            mute_until REAL NOT NULL, reason_code TEXT NOT NULL CHECK (length(reason_code) BETWEEN 1 AND 64),
            state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
            attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
            resulting_room_sequence INTEGER, terminal_code TEXT, terminal_at REAL NULL,
            CHECK ((state = 'pending' AND resulting_room_sequence IS NULL AND terminal_code IS NULL) OR (state = 'acknowledged' AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL) OR (state = 'rejected' AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL))
        );

        CREATE TABLE v2_pending_membership_commands (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                target_user_id TEXT NOT NULL,
                action TEXT NOT NULL CHECK (action IN ('add', 'remove')),
                expected_membership_revision INTEGER NOT NULL CHECK (expected_membership_revision >= 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                resulting_membership_revision INTEGER,
                resulting_room_sequence INTEGER,
                terminal_code TEXT,
                terminal_current_revision INTEGER CHECK (terminal_current_revision IS NULL OR terminal_current_revision >= 0), terminal_at REAL NULL,
                CHECK (
                    (state = 'pending' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                    OR (state = 'acknowledged' AND resulting_membership_revision IS NOT NULL AND resulting_room_sequence IS NOT NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                    OR (state = 'rejected' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                )
            );

        CREATE TABLE v2_pending_message_commands (
            client_message_id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            text TEXT NOT NULL,
            media_ids TEXT NOT NULL DEFAULT '[]',
            state TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'rejected')),
            attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
            next_attempt_at REAL NOT NULL,
            created_at REAL NOT NULL,
            accepted_message_id TEXT,
            accepted_room_sequence INTEGER,
            terminal_code TEXT, mention_targets TEXT NOT NULL DEFAULT '[]', entities TEXT NOT NULL DEFAULT '[]', reply_to_message_id TEXT, terminal_at REAL NULL,
            CHECK (
                (state = 'pending' AND accepted_message_id IS NULL AND accepted_room_sequence IS NULL AND terminal_code IS NULL)
                OR (state = 'accepted' AND accepted_message_id IS NOT NULL AND accepted_room_sequence IS NOT NULL AND accepted_room_sequence > 0 AND terminal_code IS NULL)
                OR (state = 'rejected' AND accepted_message_id IS NULL AND accepted_room_sequence IS NULL AND terminal_code IS NOT NULL)
            )
        );

        CREATE TABLE v2_pending_message_edits (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                expected_message_revision INTEGER NOT NULL CHECK (expected_message_revision > 0),
                text_body TEXT NOT NULL CHECK (length(text_body) > 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                resulting_message_revision INTEGER,
                resulting_room_sequence INTEGER,
                terminal_code TEXT,
                terminal_current_revision INTEGER, terminal_at REAL NULL,
                CHECK (
                    (state = 'pending' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                    OR (state = 'acknowledged' AND resulting_message_revision IS NOT NULL AND resulting_room_sequence IS NOT NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                    OR (state = 'rejected' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                )
            );

        CREATE TABLE v2_pending_message_favorites (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                is_favorited INTEGER NOT NULL CHECK (is_favorited IN (0, 1)),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                terminal_code TEXT, terminal_at REAL NULL,
                CHECK ((state = 'pending' AND terminal_code IS NULL) OR (state = 'acknowledged' AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
            );

        CREATE TABLE v2_pending_message_reactions (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                reaction TEXT NOT NULL CHECK (
                    length(CAST(reaction AS BLOB)) BETWEEN 1 AND 16
                ),
                action TEXT NOT NULL CHECK (action IN ('add', 'remove')),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                resulting_room_sequence INTEGER,
                terminal_code TEXT, terminal_at REAL NULL,
                CHECK (
                    (state = 'pending' AND resulting_room_sequence IS NULL AND terminal_code IS NULL)
                    OR (state = 'acknowledged' AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL)
                    OR (state = 'rejected' AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                )
            );

        CREATE TABLE v2_pending_message_redactions (
            operation_id TEXT PRIMARY KEY,
            room_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            reason_code TEXT NOT NULL CHECK (length(reason_code) > 0 AND length(reason_code) <= 64),
            state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
            attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
            next_attempt_at REAL NOT NULL,
            created_at REAL NOT NULL,
            resulting_message_revision INTEGER,
            resulting_room_sequence INTEGER,
            terminal_code TEXT, terminal_at REAL NULL,
            CHECK (
                (state = 'pending' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL)
                OR (state = 'acknowledged' AND resulting_message_revision IS NOT NULL AND resulting_message_revision > 1 AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL)
                OR (state = 'rejected' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
            )
        );

        CREATE TABLE v2_pending_message_withdrawals (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                expected_message_revision INTEGER NOT NULL CHECK (expected_message_revision > 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                resulting_message_revision INTEGER,
                resulting_room_sequence INTEGER,
                terminal_code TEXT,
                terminal_current_revision INTEGER, terminal_at REAL NULL,
                CHECK (
                    (state = 'pending' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                    OR (state = 'acknowledged' AND resulting_message_revision IS NOT NULL AND resulting_room_sequence IS NOT NULL AND terminal_code IS NULL AND terminal_current_revision IS NULL)
                    OR (state = 'rejected' AND resulting_message_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                )
            );

        CREATE TABLE v2_pending_moderated_member_removals (
            operation_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, target_user_id TEXT NOT NULL,
            reason_code TEXT NOT NULL CHECK (length(reason_code) BETWEEN 1 AND 64),
            state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
            attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL,
            resulting_membership_revision INTEGER, resulting_room_sequence INTEGER, terminal_code TEXT, terminal_at REAL NULL,
            CHECK ((state = 'pending' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NULL) OR (state = 'acknowledged' AND resulting_membership_revision IS NOT NULL AND resulting_membership_revision > 0 AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL) OR (state = 'rejected' AND resulting_membership_revision IS NULL AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL))
        );

        CREATE TABLE v2_pending_read_receipts (
                operation_id TEXT PRIMARY KEY,
                room_id TEXT NOT NULL,
                read_through_room_sequence INTEGER NOT NULL CHECK (read_through_room_sequence > 0),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0),
                next_attempt_at REAL NOT NULL,
                created_at REAL NOT NULL,
                resulting_room_sequence INTEGER,
                terminal_code TEXT, terminal_at REAL NULL,
                CHECK (
                    (state = 'pending' AND resulting_room_sequence IS NULL AND terminal_code IS NULL)
                    OR (state = 'acknowledged' AND resulting_room_sequence IS NOT NULL AND resulting_room_sequence > 0 AND terminal_code IS NULL)
                    OR (state = 'rejected' AND resulting_room_sequence IS NULL AND terminal_code IS NOT NULL)
                )
            );

        CREATE TABLE v2_pending_social_commands (
                operation_id TEXT PRIMARY KEY,
                command_kind TEXT NOT NULL CHECK (command_kind IN ('relationship', 'userBlock', 'strangerMessagePreference', 'userAddPreference', 'readReceiptPreference')),
                target_user_id TEXT, relationship_action TEXT, block_action TEXT,
                stranger_permission TEXT, user_add_permission TEXT,
                allows_direct_read_receipts INTEGER CHECK (allows_direct_read_receipts IN (0, 1)),
                allows_group_read_receipts INTEGER CHECK (allows_group_read_receipts IN (0, 1)),
                state TEXT NOT NULL CHECK (state IN ('pending', 'acknowledged', 'rejected')),
                attempt_count INTEGER NOT NULL CHECK (attempt_count >= 0), next_attempt_at REAL NOT NULL, created_at REAL NOT NULL, terminal_code TEXT, terminal_at REAL NULL,
                CHECK (
                    (command_kind = 'relationship' AND target_user_id IS NOT NULL AND relationship_action IN ('request', 'accept', 'reject', 'remove') AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IS NULL AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                    OR (command_kind = 'userBlock' AND target_user_id IS NOT NULL AND relationship_action IS NULL AND block_action IN ('block', 'unblock') AND stranger_permission IS NULL AND user_add_permission IS NULL AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                    OR (command_kind = 'strangerMessagePreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IN ('allow', 'deny') AND user_add_permission IS NULL AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                    OR (command_kind = 'userAddPreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IN ('allow', 'deny') AND allows_direct_read_receipts IS NULL AND allows_group_read_receipts IS NULL)
                    OR (command_kind = 'readReceiptPreference' AND target_user_id IS NULL AND relationship_action IS NULL AND block_action IS NULL AND stranger_permission IS NULL AND user_add_permission IS NULL AND allows_direct_read_receipts IS NOT NULL AND allows_group_read_receipts IS NOT NULL)
                ),
                CHECK ((state IN ('pending', 'acknowledged') AND terminal_code IS NULL) OR (state = 'rejected' AND terminal_code IS NOT NULL))
            );

        CREATE TABLE v2_profile_invalidations (
            user_id TEXT PRIMARY KEY,
            minimum_revision INTEGER NOT NULL CHECK (minimum_revision > 0),
            profile_state TEXT NOT NULL CHECK (profile_state IN ('active', 'deleted', 'suspended', 'hidden')),
            updated_at REAL NOT NULL
        );

        CREATE TABLE v2_profile_views (
            user_id TEXT PRIMARY KEY,
            public_handle TEXT NULL CHECK (public_handle IS NULL OR length(public_handle) BETWEEN 3 AND 32),
            display_name TEXT NULL CHECK (display_name IS NULL OR length(display_name) BETWEEN 1 AND 80),
            avatar_media_id TEXT NULL,
            state TEXT NOT NULL CHECK (state IN ('active', 'deleted', 'suspended', 'hidden')),
            revision INTEGER NOT NULL CHECK (revision > 0),
            visibility_revision INTEGER NOT NULL CHECK (visibility_revision > 0),
            account_kind TEXT NULL CHECK (account_kind IS NULL OR account_kind IN ('regular', 'system', 'customer_support')),
            updated_at REAL NOT NULL,
            CHECK ((public_handle IS NULL) = (display_name IS NULL)),
            CHECK ((state = 'active') OR (public_handle IS NULL AND avatar_media_id IS NULL))
        );

        CREATE TABLE v2_read_receipt_preference (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), preference_revision INTEGER NOT NULL CHECK (preference_revision > 0), allows_direct_read_receipts INTEGER NOT NULL CHECK (allows_direct_read_receipts IN (0, 1)), allows_group_read_receipts INTEGER NOT NULL CHECK (allows_group_read_receipts IN (0, 1)), updated_at REAL NOT NULL);

        CREATE TABLE v2_relationship_projections (
                target_user_id TEXT PRIMARY KEY,
                state TEXT NOT NULL CHECK (state IN ('none', 'pending', 'accepted')),
                requested_by_user_id TEXT,
                updated_at REAL NOT NULL,
                CHECK ((state = 'pending' AND requested_by_user_id IS NOT NULL) OR (state <> 'pending' AND requested_by_user_id IS NULL))
            );

        CREATE TABLE v2_reset_rollback (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                generation INTEGER NOT NULL CHECK (generation > 0),
                applied_sequence INTEGER NOT NULL CHECK (applied_sequence >= 0),
                server_acknowledged_sequence INTEGER NOT NULL CHECK (server_acknowledged_sequence >= 0),
                CHECK (server_acknowledged_sequence <= applied_sequence)
            );

        CREATE TABLE v2_room_control_projections (
            room_id TEXT PRIMARY KEY,
            source_event_id TEXT NOT NULL UNIQUE,
            room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
            actor_user_id TEXT NOT NULL,
            is_frozen INTEGER NOT NULL CHECK (is_frozen IN (0, 1)),
            server_created_at REAL NOT NULL
        );

        CREATE TABLE v2_room_membership_states (
            room_id TEXT PRIMARY KEY,
            membership_revision INTEGER NOT NULL CHECK (membership_revision > 0),
            source_event_id TEXT NOT NULL,
            is_member INTEGER NOT NULL CHECK (is_member IN (0, 1))
        );

        CREATE TABLE v2_room_profile_projections (
                room_id TEXT PRIMARY KEY,
                source_event_id TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                owner_user_id TEXT NOT NULL,
                membership_revision INTEGER NOT NULL DEFAULT 1 CHECK (membership_revision > 0),
                capacity_class TEXT NOT NULL CHECK (capacity_class IN ('standard', 'large')),

                is_group_event_authorized INTEGER NOT NULL DEFAULT 1 CHECK (is_group_event_authorized IN (0, 1)),
                created_at REAL NOT NULL
            );

        CREATE TABLE v2_snapshot_import (
                snapshot_id TEXT PRIMARY KEY,
                generation INTEGER NOT NULL CHECK (generation > 0),
                base_sequence INTEGER NOT NULL CHECK (base_sequence >= 0),
                root_digest TEXT NOT NULL,
                next_sync_token TEXT NOT NULL,
                receipt TEXT NOT NULL,
                capability_profile TEXT NOT NULL,
                page_count INTEGER NOT NULL CHECK (page_count >= 0),
                total_items INTEGER NOT NULL CHECK (total_items >= 0),
                total_bytes INTEGER NOT NULL CHECK (total_bytes >= 0),
                next_page_index INTEGER NOT NULL DEFAULT 0 CHECK (next_page_index >= 0),
                rolling_digest TEXT NOT NULL,
                last_projection_kind TEXT,
                last_entity_key TEXT,
                applied_items INTEGER NOT NULL DEFAULT 0 CHECK (applied_items >= 0),
                applied_bytes INTEGER NOT NULL DEFAULT 0 CHECK (applied_bytes >= 0),
                activation_prepared INTEGER NOT NULL DEFAULT 0 CHECK (activation_prepared IN (0, 1)),
                CHECK ((last_projection_kind IS NULL) = (last_entity_key IS NULL)),
                CHECK (next_page_index <= page_count)
            );

        CREATE TABLE v2_snapshots (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                snapshot_id TEXT NOT NULL,
                generation INTEGER NOT NULL,
                base_sequence INTEGER NOT NULL,
                root_digest TEXT NOT NULL,
                next_sync_token TEXT NOT NULL,
                acknowledgement_receipt TEXT
            );

        CREATE TABLE v2_stranger_message_preference (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                allows_stranger_messages INTEGER NOT NULL CHECK (allows_stranger_messages IN (0, 1)),
                updated_at REAL NOT NULL
            );

        CREATE TABLE v2_sync_cursor (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                state TEXT NOT NULL CHECK (state IN ('ready', 'resetPending')),
                generation INTEGER NOT NULL CHECK (generation > 0),
                applied_sequence INTEGER NOT NULL CHECK (applied_sequence >= 0),
                server_acknowledged_sequence INTEGER NOT NULL CHECK (server_acknowledged_sequence >= 0),
                sync_token TEXT,
                pending_ack_receipt TEXT,
                pending_ack_sequence INTEGER,
                pending_snapshot_id TEXT,
                pending_base_sequence INTEGER,
                pending_expires_at REAL,
                CHECK ((pending_ack_receipt IS NULL AND pending_ack_sequence IS NULL) OR (pending_ack_receipt IS NOT NULL AND pending_ack_sequence > server_acknowledged_sequence AND pending_ack_sequence <= applied_sequence))
            );

        CREATE TABLE v2_sync_events (
                sequence INTEGER PRIMARY KEY CHECK (sequence > 0),
                source_event_id TEXT NOT NULL,
                projection_kind TEXT NOT NULL,
                payload BLOB NOT NULL,
                UNIQUE (source_event_id, projection_kind)
            );

        CREATE TABLE v2_timeline_activity_projections (source_event_id TEXT PRIMARY KEY, room_id TEXT NOT NULL, timeline_sequence INTEGER NOT NULL CHECK (timeline_sequence > 0), event_type TEXT NOT NULL CHECK (event_type IN ('direct_message_restricted', 'system_account_read_only')), server_created_at REAL NOT NULL, UNIQUE (room_id, timeline_sequence));

        CREATE TABLE v2_user_add_preference (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            allows_being_added INTEGER NOT NULL CHECK (allows_being_added IN (0, 1)),
            updated_at REAL NOT NULL
        );

        CREATE TABLE v2_user_block_projections (
                target_user_id TEXT PRIMARY KEY,
                is_blocked INTEGER NOT NULL CHECK (is_blocked IN (0, 1)),
                updated_at REAL NOT NULL
            );

        CREATE INDEX v2_conversation_list_page_idx
                ON v2_conversation_list_entries
                (is_archived, is_pinned DESC, last_activity DESC, room_id ASC);

        CREATE INDEX v2_conversation_states_list_idx ON v2_conversation_states (is_archived, is_pinned DESC, updated_at DESC);

        CREATE UNIQUE INDEX v2_direct_room_identities_target_idx
            ON v2_direct_room_identities (target_user_id);

        CREATE INDEX v2_forward_message_chunks_ready_idx
                ON v2_forward_message_chunks (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_forward_message_plans_active_expiry_idx ON v2_forward_message_plans (created_at) WHERE state = 'active';

        CREATE INDEX v2_forward_message_plans_active_idx
                ON v2_forward_message_plans (created_at, plan_id) WHERE state = 'active';

        CREATE INDEX v2_forward_message_plans_terminal_cleanup_idx ON v2_forward_message_plans (updated_at) WHERE state IN ('completed', 'cancelled');

        -- Sparse indexes retain only invalid stored sequences; empty for valid data.
        CREATE INDEX v2_group_event_cursors_invalid_sequence_idx ON v2_group_event_cursors (room_id) WHERE (typeof(applied_room_sequence) <> 'integer' OR applied_room_sequence < 0);
        CREATE INDEX v2_group_events_invalid_sequence_idx ON v2_group_events (room_id) WHERE (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_message_projections_invalid_sequence_idx ON v2_message_projections (room_id) WHERE (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_reaction_versions_invalid_sequence_idx ON v2_reaction_versions (room_id) WHERE (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_group_pinned_messages_invalid_sequence_idx ON v2_group_pinned_messages (room_id) WHERE room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_group_announcements_invalid_sequence_idx ON v2_group_announcements (room_id) WHERE room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_group_role_policies_invalid_sequence_idx ON v2_group_role_policies (room_id) WHERE room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_group_member_roles_invalid_sequence_idx ON v2_group_member_roles (room_id) WHERE (typeof(room_sequence) <> 'integer' OR room_sequence < 1);
        CREATE INDEX v2_reaction_versions_sequence_idx ON v2_reaction_versions (room_id, room_sequence);
        CREATE INDEX v2_group_member_roles_sequence_idx ON v2_group_member_roles (room_id, room_sequence);
        CREATE INDEX v2_group_pinned_messages_sequence_idx ON v2_group_pinned_messages (room_id, room_sequence);

        CREATE INDEX v2_group_pinned_messages_room_idx ON v2_group_pinned_messages (room_id, is_pinned DESC, updated_at DESC);

        CREATE INDEX v2_message_favorites_room_idx ON v2_message_favorites (room_id, is_favorited, updated_at DESC);

        CREATE INDEX v2_message_projections_room_order_idx
            ON v2_message_projections (room_id, room_sequence, message_id);

        CREATE UNIQUE INDEX v2_message_projections_room_timeline_idx ON v2_message_projections (room_id, timeline_sequence);

        CREATE INDEX v2_message_reactions_message_idx
                ON v2_message_reactions (message_id, reaction, actor_user_id);

        CREATE INDEX v2_message_search_jobs_generation_idx
                ON v2_message_search_jobs (generation, enqueued_at, message_id);

        CREATE INDEX v2_moderation_projections_room_idx
            ON v2_moderation_projections (room_id, server_created_at, source_event_id);

        CREATE INDEX v2_pending_conversation_states_idempotency_expiry_idx ON v2_pending_conversation_states (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_conversation_states_ready_idx ON v2_pending_conversation_states (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_conversation_states_terminal_cleanup_idx ON v2_pending_conversation_states (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_forward_messages_idempotency_expiry_idx ON v2_pending_forward_messages (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_forward_messages_ready_idx ON v2_pending_forward_messages (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_forward_messages_terminal_cleanup_idx ON v2_pending_forward_messages (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_group_capabilities_idempotency_expiry_idx ON v2_pending_group_capabilities (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_group_capabilities_ready_idx ON v2_pending_group_capabilities (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_group_capabilities_terminal_cleanup_idx ON v2_pending_group_capabilities (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_group_room_creations_active_expiry_idx ON v2_pending_group_room_creations (created_at) WHERE state IN ('finalizing', 'cancelling');

        CREATE INDEX v2_pending_group_room_creations_idempotency_expiry_idx ON v2_pending_group_room_creations (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_group_room_creations_intent_with_capacity_class_idx
                ON v2_pending_group_room_creations
                (title, capacity_class, initial_member_user_ids, created_at, operation_id)
                WHERE state IN ('pending', 'finalizing');

        CREATE INDEX v2_pending_group_room_creations_ready_idx
                ON v2_pending_group_room_creations (state, next_attempt_at, created_at)
                WHERE state IN ('pending', 'finalizing', 'cancelling');

        CREATE INDEX v2_pending_group_room_creations_terminal_cleanup_idx ON v2_pending_group_room_creations (terminal_at) WHERE state IN ('cancelled', 'acknowledged', 'rejected');

        CREATE INDEX v2_pending_member_mutes_idempotency_expiry_idx ON v2_pending_member_mutes (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_member_mutes_intent_idx
                ON v2_pending_member_mutes
                (room_id, target_user_id, mute_until, reason_code, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_member_mutes_ready_idx ON v2_pending_member_mutes (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_member_mutes_terminal_cleanup_idx ON v2_pending_member_mutes (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_membership_commands_idempotency_expiry_idx ON v2_pending_membership_commands (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_membership_commands_terminal_cleanup_idx ON v2_pending_membership_commands (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_membership_intent_idx
                ON v2_pending_membership_commands
                (room_id, target_user_id, action, expected_membership_revision, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_membership_ready_idx
                ON v2_pending_membership_commands (state, next_attempt_at, created_at)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_commands_idempotency_expiry_idx ON v2_pending_message_commands (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_commands_terminal_cleanup_idx ON v2_pending_message_commands (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_message_edits_idempotency_expiry_idx ON v2_pending_message_edits (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_edits_intent_idx
                ON v2_pending_message_edits
                (room_id, message_id, expected_message_revision, text_body, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_edits_ready_idx
                ON v2_pending_message_edits (state, next_attempt_at, created_at)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_edits_terminal_cleanup_idx ON v2_pending_message_edits (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_message_favorites_idempotency_expiry_idx ON v2_pending_message_favorites (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_favorites_ready_idx ON v2_pending_message_favorites (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_favorites_terminal_cleanup_idx ON v2_pending_message_favorites (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_message_reactions_idempotency_expiry_idx ON v2_pending_message_reactions (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_reactions_intent_idx
                ON v2_pending_message_reactions
                (room_id, message_id, reaction, action, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_reactions_ready_idx
                ON v2_pending_message_reactions (state, next_attempt_at, created_at)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_reactions_terminal_cleanup_idx ON v2_pending_message_reactions (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_message_ready_idx
            ON v2_pending_message_commands (state, next_attempt_at, created_at)
            WHERE state = 'pending';

        CREATE INDEX v2_pending_message_redactions_idempotency_expiry_idx ON v2_pending_message_redactions (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_redactions_intent_idx
                ON v2_pending_message_redactions
                (room_id, message_id, reason_code, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_redactions_ready_idx
            ON v2_pending_message_redactions (state, next_attempt_at, created_at)
            WHERE state = 'pending';

        CREATE INDEX v2_pending_message_redactions_terminal_cleanup_idx ON v2_pending_message_redactions (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_message_withdrawals_idempotency_expiry_idx ON v2_pending_message_withdrawals (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_message_withdrawals_intent_idx
                ON v2_pending_message_withdrawals
                (room_id, message_id, expected_message_revision, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_withdrawals_ready_idx
                ON v2_pending_message_withdrawals (state, next_attempt_at, created_at)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_message_withdrawals_terminal_cleanup_idx ON v2_pending_message_withdrawals (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_moderated_member_removals_idempotency_expiry_idx ON v2_pending_moderated_member_removals (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_moderated_member_removals_intent_idx
                ON v2_pending_moderated_member_removals
                (room_id, target_user_id, reason_code, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_moderated_member_removals_ready_idx ON v2_pending_moderated_member_removals (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_moderated_member_removals_terminal_cleanup_idx ON v2_pending_moderated_member_removals (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_read_receipts_idempotency_expiry_idx ON v2_pending_read_receipts (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_read_receipts_ready_idx
                ON v2_pending_read_receipts (state, next_attempt_at, created_at)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_read_receipts_terminal_cleanup_idx ON v2_pending_read_receipts (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_social_commands_idempotency_expiry_idx ON v2_pending_social_commands (created_at) WHERE state = 'pending';

        CREATE INDEX v2_pending_social_commands_intent_idx
                ON v2_pending_social_commands
                (command_kind, target_user_id, relationship_action, block_action, stranger_permission, created_at, operation_id)
                WHERE state = 'pending';

        CREATE INDEX v2_pending_social_commands_terminal_cleanup_idx ON v2_pending_social_commands (terminal_at) WHERE state <> 'pending';

        CREATE INDEX v2_pending_social_ready_idx ON v2_pending_social_commands (state, next_attempt_at, created_at) WHERE state = 'pending';

        CREATE INDEX v2_relationship_list_requester_page_idx
                ON v2_relationship_projections
                (state, requested_by_user_id, updated_at DESC, target_user_id ASC);

        CREATE INDEX v2_relationship_list_state_page_idx
                ON v2_relationship_projections
                (state, updated_at DESC, target_user_id ASC);

        CREATE INDEX v2_room_profile_authorized_delivery_idx
                ON v2_room_profile_projections (capacity_class, room_id)
                WHERE is_group_event_authorized = 1;

        CREATE INDEX v2_timeline_activity_room_order_idx ON v2_timeline_activity_projections (room_id, timeline_sequence, source_event_id);

        CREATE TRIGGER v2_contact_profile_search_delete
            AFTER DELETE ON v2_profile_views
            BEGIN
                DELETE FROM v2_contact_profile_search WHERE rowid = OLD.rowid;
            END;

        CREATE TRIGGER v2_contact_profile_search_insert
            AFTER INSERT ON v2_profile_views
            WHEN NEW.public_handle IS NOT NULL
            BEGIN
                INSERT INTO v2_contact_profile_search
                    (rowid, display_unigrams, display_bigrams, handle_unigrams, handle_bigrams)
                VALUES (
                    NEW.rowid,
                    v2_contact_search_unigrams(NEW.display_name),
                    v2_contact_search_bigrams(NEW.display_name),
                    v2_contact_search_unigrams(NEW.public_handle),
                    v2_contact_search_bigrams(NEW.public_handle)
                );
            END;

        CREATE TRIGGER v2_contact_profile_search_update
            AFTER UPDATE OF public_handle, display_name ON v2_profile_views
            BEGIN
                DELETE FROM v2_contact_profile_search WHERE rowid = OLD.rowid;
                INSERT INTO v2_contact_profile_search
                    (rowid, display_unigrams, display_bigrams, handle_unigrams, handle_bigrams)
                SELECT NEW.rowid,
                       v2_contact_search_unigrams(NEW.display_name),
                       v2_contact_search_bigrams(NEW.display_name),
                       v2_contact_search_unigrams(NEW.public_handle),
                       v2_contact_search_bigrams(NEW.public_handle)
                WHERE NEW.public_handle IS NOT NULL;
            END;

        CREATE TRIGGER v2_conversation_list_direct_cache_delete
            AFTER DELETE ON v2_direct_room_identities
            BEGIN
                DELETE FROM v2_conversation_list_entries
                WHERE room_id = OLD.room_id
                  AND NOT EXISTS (SELECT 1 FROM v2_room_latest_visible WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_conversation_summaries WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = OLD.room_id);
            END;

        CREATE TRIGGER v2_conversation_list_direct_cache_insert
            AFTER INSERT ON v2_direct_room_identities
            BEGIN
                INSERT INTO v2_conversation_list_entries
                    (room_id, last_activity, is_pinned, is_archived, mute_until)
                VALUES (
                    NEW.room_id,
                    COALESCE(
                        (SELECT message.server_created_at FROM v2_conversation_summaries AS summary JOIN v2_message_projections AS message ON message.message_id = summary.message_id WHERE summary.room_id = NEW.room_id),
                        (SELECT created_at FROM v2_room_profile_projections WHERE room_id = NEW.room_id),
                        (SELECT room_created_at FROM v2_direct_room_profile_projections WHERE room_id = NEW.room_id),
                        NEW.room_created_at
                    ),
                    COALESCE((SELECT is_pinned FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                    COALESCE((SELECT is_archived FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                    COALESCE((SELECT mute_until FROM v2_conversation_states WHERE room_id = NEW.room_id), 0)
                )
                ON CONFLICT(room_id) DO UPDATE SET last_activity = excluded.last_activity;
            END;

        CREATE TRIGGER v2_conversation_list_direct_cache_update
            AFTER UPDATE OF room_created_at ON v2_direct_room_identities
            WHEN NOT EXISTS (SELECT 1 FROM v2_conversation_summaries WHERE room_id = NEW.room_id)
             AND NOT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = NEW.room_id)
             AND NOT EXISTS (SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = NEW.room_id)
            BEGIN
                UPDATE v2_conversation_list_entries SET last_activity = NEW.room_created_at WHERE room_id = NEW.room_id;
            END;

        CREATE TRIGGER v2_conversation_list_direct_profile_delete
            AFTER DELETE ON v2_direct_room_profile_projections
            BEGIN
                UPDATE v2_conversation_list_entries
                SET last_activity = COALESCE(
                    (SELECT message.server_created_at FROM v2_conversation_summaries AS summary JOIN v2_message_projections AS message ON message.message_id = summary.message_id WHERE summary.room_id = OLD.room_id),
                    (SELECT created_at FROM v2_room_profile_projections WHERE room_id = OLD.room_id),
                    (SELECT room_created_at FROM v2_direct_room_identities WHERE room_id = OLD.room_id),
                    last_activity
                )
                WHERE room_id = OLD.room_id;
                DELETE FROM v2_conversation_list_entries
                WHERE room_id = OLD.room_id
                  AND NOT EXISTS (SELECT 1 FROM v2_room_latest_visible WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_conversation_summaries WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_direct_room_identities WHERE room_id = OLD.room_id);
            END;

        CREATE TRIGGER v2_conversation_list_direct_profile_insert
            AFTER INSERT ON v2_direct_room_profile_projections
            BEGIN
                INSERT INTO v2_conversation_list_entries
                    (room_id, last_activity, is_pinned, is_archived, mute_until)
                VALUES (
                    NEW.room_id,
                    COALESCE(
                        (SELECT message.server_created_at FROM v2_conversation_summaries AS summary JOIN v2_message_projections AS message ON message.message_id = summary.message_id WHERE summary.room_id = NEW.room_id),
                        (SELECT created_at FROM v2_room_profile_projections WHERE room_id = NEW.room_id),
                        NEW.room_created_at
                    ),
                    COALESCE((SELECT is_pinned FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                    COALESCE((SELECT is_archived FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                    COALESCE((SELECT mute_until FROM v2_conversation_states WHERE room_id = NEW.room_id), 0)
                )
                ON CONFLICT(room_id) DO UPDATE SET last_activity = excluded.last_activity;
            END;

        CREATE TRIGGER v2_conversation_list_direct_profile_update
            AFTER UPDATE OF room_created_at ON v2_direct_room_profile_projections
            WHEN NOT EXISTS (SELECT 1 FROM v2_conversation_summaries WHERE room_id = NEW.room_id)
             AND NOT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = NEW.room_id)
            BEGIN
                UPDATE v2_conversation_list_entries SET last_activity = NEW.room_created_at WHERE room_id = NEW.room_id;
            END;

        CREATE TRIGGER v2_conversation_list_room_profile_delete
            AFTER DELETE ON v2_room_profile_projections
            BEGIN
                UPDATE v2_conversation_list_entries
                SET last_activity = COALESCE(
                    (SELECT message.server_created_at FROM v2_conversation_summaries AS summary JOIN v2_message_projections AS message ON message.message_id = summary.message_id WHERE summary.room_id = OLD.room_id),
                    (SELECT room_created_at FROM v2_direct_room_profile_projections WHERE room_id = OLD.room_id),
                    (SELECT room_created_at FROM v2_direct_room_identities WHERE room_id = OLD.room_id),
                    last_activity
                )
                WHERE room_id = OLD.room_id;
                DELETE FROM v2_conversation_list_entries
                WHERE room_id = OLD.room_id
                  AND NOT EXISTS (SELECT 1 FROM v2_room_latest_visible WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_conversation_summaries WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_direct_room_identities WHERE room_id = OLD.room_id);
            END;

        CREATE TRIGGER v2_conversation_list_room_profile_insert
            AFTER INSERT ON v2_room_profile_projections
            BEGIN
                INSERT INTO v2_conversation_list_entries
                    (room_id, last_activity, is_pinned, is_archived, mute_until)
                VALUES (
                    NEW.room_id,
                    COALESCE(
                        (SELECT message.server_created_at FROM v2_conversation_summaries AS summary JOIN v2_message_projections AS message ON message.message_id = summary.message_id WHERE summary.room_id = NEW.room_id),
                        NEW.created_at
                    ),
                    COALESCE((SELECT is_pinned FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                    COALESCE((SELECT is_archived FROM v2_conversation_states WHERE room_id = NEW.room_id), 0),
                    COALESCE((SELECT mute_until FROM v2_conversation_states WHERE room_id = NEW.room_id), 0)
                )
                ON CONFLICT(room_id) DO UPDATE SET last_activity = excluded.last_activity;
            END;

        CREATE TRIGGER v2_conversation_list_state_delete
            AFTER DELETE ON v2_conversation_states
            BEGIN
                UPDATE v2_conversation_list_entries
                SET is_pinned = 0, is_archived = 0, mute_until = 0
                WHERE room_id = OLD.room_id;
            END;

        CREATE TRIGGER v2_conversation_list_state_insert
            AFTER INSERT ON v2_conversation_states
            BEGIN
                UPDATE v2_conversation_list_entries
                SET is_pinned = NEW.is_pinned, is_archived = NEW.is_archived, mute_until = NEW.mute_until
                WHERE room_id = NEW.room_id;
            END;

        CREATE TRIGGER v2_conversation_list_state_update
            AFTER UPDATE OF is_pinned, is_archived, mute_until ON v2_conversation_states
            BEGIN
                UPDATE v2_conversation_list_entries
                SET is_pinned = NEW.is_pinned, is_archived = NEW.is_archived, mute_until = NEW.mute_until
                WHERE room_id = NEW.room_id;
            END;

        CREATE TRIGGER v2_conversation_list_summary_delete
            AFTER DELETE ON v2_conversation_summaries
            BEGIN
                UPDATE v2_conversation_list_entries
                SET last_activity = COALESCE(
                    (SELECT created_at FROM v2_room_profile_projections WHERE room_id = OLD.room_id),
                    (SELECT room_created_at FROM v2_direct_room_profile_projections WHERE room_id = OLD.room_id),
                    (SELECT room_created_at FROM v2_direct_room_identities WHERE room_id = OLD.room_id),
                    last_activity
                )
                WHERE room_id = OLD.room_id;
                DELETE FROM v2_conversation_list_entries
                WHERE room_id = OLD.room_id
                  AND NOT EXISTS (SELECT 1 FROM v2_room_latest_visible WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = OLD.room_id)
                  AND NOT EXISTS (SELECT 1 FROM v2_direct_room_identities WHERE room_id = OLD.room_id);
            END;

        CREATE TRIGGER v2_conversation_list_summary_insert
            AFTER INSERT ON v2_conversation_summaries
            BEGIN
                INSERT INTO v2_conversation_list_entries
                    (room_id, last_activity, is_pinned, is_archived, mute_until)
                SELECT NEW.room_id, message.server_created_at,
                       COALESCE(state.is_pinned, 0), COALESCE(state.is_archived, 0), COALESCE(state.mute_until, 0)
                FROM v2_message_projections AS message
                LEFT JOIN v2_conversation_states AS state ON state.room_id = NEW.room_id
                WHERE message.message_id = NEW.message_id
                ON CONFLICT(room_id) DO UPDATE SET
                    last_activity = excluded.last_activity,
                    is_pinned = excluded.is_pinned,
                    is_archived = excluded.is_archived,
                    mute_until = excluded.mute_until;
            END;

        CREATE TRIGGER v2_conversation_list_summary_update
            AFTER UPDATE OF message_id ON v2_conversation_summaries
            BEGIN
                UPDATE v2_conversation_list_entries
                SET last_activity = (SELECT server_created_at FROM v2_message_projections WHERE message_id = NEW.message_id)
                WHERE room_id = NEW.room_id;
            END;

        CREATE TRIGGER v2_pending_conversation_states_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_conversation_states
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_conversation_states
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_forward_messages_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_forward_messages
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_forward_messages
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_group_capabilities_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_group_capabilities
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_group_capabilities
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_group_room_creations_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_group_room_creations
        WHEN NEW.terminal_at IS NULL AND NEW.state IN ('cancelled', 'acknowledged', 'rejected')
        BEGIN
            UPDATE v2_pending_group_room_creations
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_member_mutes_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_member_mutes
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_member_mutes
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_membership_commands_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_membership_commands
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_membership_commands
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_message_commands_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_message_commands
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_message_commands
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_message_edits_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_message_edits
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_message_edits
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_message_favorites_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_message_favorites
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_message_favorites
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_message_reactions_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_message_reactions
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_message_reactions
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_message_redactions_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_message_redactions
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_message_redactions
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_message_withdrawals_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_message_withdrawals
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_message_withdrawals
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_moderated_member_removals_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_moderated_member_removals
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_moderated_member_removals
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_read_receipts_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_read_receipts
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_read_receipts
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        CREATE TRIGGER v2_pending_social_commands_set_terminal_at
        AFTER UPDATE OF state ON v2_pending_social_commands
        WHEN NEW.terminal_at IS NULL AND NEW.state <> 'pending'
        BEGIN
            UPDATE v2_pending_social_commands
            SET terminal_at = (julianday('now') - 2440587.5) * 86400.0
            WHERE rowid = NEW.rowid;
        END;

        INSERT INTO v2_message_search_state
            (singleton, index_version, state, generation)
        VALUES (1, 1, 'building', 1);
        \(roomLatestVisibleTriggersSQL)
        \(roomLatestVisibleListTriggersSQL)
        """
}
