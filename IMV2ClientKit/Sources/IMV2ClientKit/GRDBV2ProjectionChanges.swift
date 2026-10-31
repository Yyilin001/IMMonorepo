import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// 订阅本地投影变更。
    ///
    /// 订阅会立即给出一次全量失效，因此打开页面时不需要依赖观察到订阅之前已经提交的事务。
    ///
    /// - Returns: 变更订阅句柄。
    public nonisolated func installNetworkDiagnostics(_ diagnostics: V2NetworkDiagnostics) { projectionChangeHub.installDiagnostics(diagnostics) }

    public func projectionChanges() -> V2ProjectionChangeSubscription { projectionChangeHub.subscribe() }
}

/// 投影事务观察者。
///
/// 该对象只在 GRDB 写入队列上创建并持有：跨队列传递的只有 `Sendable` 的变更中枢与不可变变更摘要，
/// 观察者实例与可变待定值都不跨界。GRDB 会缓存保存点期间的变更并在提交或回滚时回调，
/// 因此推测性写入不会传给订阅者。
final class V2ProjectionTransactionObserver: TransactionObserver {
    private let hub: V2ProjectionChangeHub
    private var pending = V2ProjectionChange.none
    private var roomRows: [String: Set<Int64>] = [:]
    private var hasUnscopedRoomChange = false
    private var willCommit: ContinuousClock.Instant?
    /// 以变更中枢构造观察者。
    ///
    /// - Parameter hub: 接收已提交变更的中枢。
    init(hub: V2ProjectionChangeHub) { self.hub = hub }

    /// 判断是否需要观察该类型的事件。
    ///
    /// - Parameter kind: 数据库事件类型。
    /// - Returns: 该表的插入事件会映射到至少一个可见作用域时为 `true`。
    func observes(eventsOfKind kind: DatabaseEventKind) -> Bool {
        !Self.change(table: kind.tableName, kind: .insert).scopes.isEmpty
    }
    /// 累积本次事务内的变更。
    ///
    /// - Parameter event: 数据库变更事件。
    func databaseDidChange(with event: DatabaseEvent) {
        let change = Self.change(table: event.tableName, kind: event.kind)
        pending = pending.merging(change)
        if change.scopes.contains(.conversationTimeline), Self.roomScopedTables.contains(event.tableName) {
            if event.kind == .delete { hasUnscopedRoomChange = true }
            else {
                if !hasUnscopedRoomChange {
                    roomRows[event.tableName, default: []].insert(event.rowID)
                    if roomRows.values.reduce(0, { $0 + $1.count }) > 256 { hasUnscopedRoomChange = true; roomRows.removeAll() }
                }
            }
        } else if change.scopes.contains(.conversationDetails) || change.scopes.contains(.conversationMetadata) {
            hasUnscopedRoomChange = true
        }
    }
    func databaseWillCommit() throws {
        willCommit = .now
    }
    /// 事务提交后发布累积的变更。
    ///
    /// - Parameter db: 已提交的数据库。
    func databaseDidCommit(_ db: Database) {
        let didCommit = ContinuousClock.now
        var committed = pending
        if !roomRows.isEmpty, !hasUnscopedRoomChange {
            var rooms = Set<String>()
            for (table, rowIDs) in roomRows {
                let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
                guard let roomIDs = try? String.fetchAll(db, sql: "SELECT DISTINCT room_id FROM \(table) WHERE rowid IN (\(placeholders))", arguments: StatementArguments(rowIDs.sorted())) else {
                    hasUnscopedRoomChange = true; break
                }
                rooms.formUnion(roomIDs)
                if rooms.count > 32 { hasUnscopedRoomChange = true; break }
            }
            if !hasUnscopedRoomChange { committed = .init(scopes: committed.scopes, requiresImmediateRefresh: committed.requiresImmediateRefresh, roomIDs: rooms) }
        }
        pending = .none
        roomRows.removeAll(keepingCapacity: true)
        let unscoped = hasUnscopedRoomChange
        hasUnscopedRoomChange = false
        let sink = hub.diagnosticSink()
        if !committed.scopes.isEmpty, let willCommit, let sink {
            let duration = willCommit.duration(to: didCommit).components
            sink.record(.init(phase: .willCommitToDidCommit,
                elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18, scopes: committed.scopes))
        }
        willCommit = nil
        let stamp: V2ConversationCommitMeasurement?
        if committed.scopes.contains(.conversations), let sink {
            stamp = .init(committedAt: didCommit, diagnostics: sink)
        } else { stamp = nil }
        hub.publish(.init(scopes: committed.scopes, requiresImmediateRefresh: committed.requiresImmediateRefresh, conversationCommit: stamp,
            roomIDs: unscoped ? nil : committed.roomIDs))
    }
    /// 事务回滚后丢弃累积的变更。
    ///
    /// - Parameter db: 已回滚的数据库。
    func databaseDidRollback(_ db: Database) { pending = .none; roomRows.removeAll(); hasUnscopedRoomChange = false; willCommit = nil }

    private static let roomScopedTables: Set<String> = ["v2_message_projections", "v2_message_reactions", "v2_direct_read_receipt_projections", "v2_room_read_watermarks"]

    /// 把单张表的变更映射到可见作用域。
    ///
    /// 影子库表在激活期间原子切换 `v2_snapshots` 之前不可见，全文索引维护另有就绪观察者，
    /// 因此这些表一律返回无变更。派生汇总行可能因普通新消息被删除重建，
    /// 其来源投影会单独触发立即刷新。未知表默认返回全量变更，避免未来的投影被静默延迟或隐藏。
    ///
    /// - Parameters:
    ///   - table: 表名。
    ///   - kind: 事件类型。
    /// - Returns: 该表变更对应的作用域与刷新要求。
    static func change(table: String, kind: DatabaseEvent.Kind) -> V2ProjectionChange {
        // Shadow banks are not visible until v2_snapshots is atomically changed
        // during activation. FTS maintenance has its own index-ready observer.
        if table.hasPrefix("v2_snapshot_shadow_") || table.hasPrefix("v2_snapshot_retired_") ||
            table.hasPrefix("v2_contact_profile_search") || table.hasPrefix("sqlite_") { return .none }
        let conversation: V2ProjectionScopes = [.conversations, .conversationDetails]
        switch table {
        case "v2_profile_intents":
            return .init(scopes: .resources, requiresImmediateRefresh: false)
        case "v2_operation_work", "v2_operation_dependencies", "v2_own_profile_snapshot",
             "v2_personal_preference_intents", "v2_personal_preference_confirmed", "v2_name_operations", "v2_name_confirmed":
            // These are observed by their owning intent/editor streams. Retry
            // metadata cannot revoke every visible profile's authorization.
            return .none
        case "v2_resource_files", "v2_resource_file_consumers", "v2_resource_file_pins", "v2_resource_local_assets", "v2_resource_entries", "v2_resource_cached_versions",
             "v2_resource_variants", "v2_resource_retention_intents",
             "v2_resource_storage_policy", "v2_resource_download_network_preferences", "v2_resource_projection_index_jobs",
             "v2_resource_background_upload_sources",
             "v2_resource_transfer_jobs", "v2_resource_import_jobs", "v2_resource_download_jobs",
             "v2_background_transfer_tasks":
            return .init(scopes: .resources, requiresImmediateRefresh: false)
        case "v2_resource_references", "v2_resource_access_generation", "v2_resource_room_denials":
            return .init(scopes: .resources, requiresImmediateRefresh: true)
        case "v2_local_profile_display", "v2_resource_file_operations", "v2_resource_query_checkpoints": return .none
        case "v2_resource_transfer_staging": return .init(scopes: .resources, requiresImmediateRefresh: false)
        case "v2_room_recovery_work", "v2_room_recovery_scan", "v2_send_intent_dependencies", "v2_send_intent_import_dependencies":
            return .none
        case "v2_room_sync_states", "v2_room_latest_visible":
            return .init(scopes: conversation, requiresImmediateRefresh: kind == .delete)
        case "v2_sync_rebuild_requests", "v2_sync_cursor", "v2_sync_events", "v2_group_events", "v2_group_event_cursors",
             "v2_snapshot_import", "v2_reset_rollback",
             "v2_local_installation", "v2_push_intent", "v2_message_search_jobs", "v2_message_search_state", "v2_message_effects", "v2_reaction_versions", "v2_reaction_effects", "v2_announcement_effects", "v2_pin_effects", "v2_role_policy_effects":
            return .none
        // Derived summary rows may be deleted/reinserted for an ordinary new
        // message. Their source projection separately raises urgent changes.
        case "v2_conversation_list_entries", "v2_conversation_summaries":
            return .init(scopes: .conversations, requiresImmediateRefresh: false)
        case "v2_message_projections":
            return .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: kind != .insert)
        case "v2_room_profile_projections", "v2_direct_room_profile_projections", "v2_direct_room_identities":
            return .init(scopes: [.conversations, .conversationDetails], requiresImmediateRefresh: kind != .insert)
        case "v2_profile_views":
            return .init(scopes: [.contacts, .conversations, .conversationDetails, .presentations], requiresImmediateRefresh: kind != .insert)
        case "v2_role_policy_recovery_requests":
            return .init(scopes: .conversationMetadata, requiresImmediateRefresh: false)
        case "v2_message_reactions", "v2_direct_read_receipt_projections", "v2_room_read_watermarks", "v2_message_reaction_intents", "v2_read_receipt_intents", "v2_read_receipt_operations":
            return .init(scopes: .conversationTimeline, requiresImmediateRefresh: false)
        case "v2_read_receipt_archives":
            return .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: false)
        case "v2_send_intents", "v2_message_send_operations", "v2_forward_plan_operations":
            return .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: false)
        case "v2_group_avatar_effects", "v2_group_nickname_effects": return .none
        case "v2_group_nickname_invalidations":
            return .init(scopes: .groupNicknames, requiresImmediateRefresh: true)
        case "v2_contact_alias_invalidations":
            return .init(scopes: .contactAliases, requiresImmediateRefresh: true)
        case "v2_group_avatar_intents":
            // Local retries/claims only change management status. They cannot
            // invalidate every visible avatar's authorization and cause refetches.
            return .init(scopes: [.conversationDetails, .resources], requiresImmediateRefresh: true)
        case "v2_room_event_authorizations", "v2_group_member_roles", "v2_room_control_projections", "v2_group_avatar_invalidations":
            return .init(scopes: [.conversations, .conversationDetails, .presentations], requiresImmediateRefresh: true)
        case "v2_message_favorites", "v2_group_pinned_messages", "v2_timeline_activity_projections", "v2_message_mutation_operations":
            return .init(scopes: [.conversations, .conversationTimeline], requiresImmediateRefresh: true)
        case "v2_message_tombstones", "v2_moderation_projections", "v2_message_moderation_operations":
            return .init(scopes: [.conversations, .conversationDetails], requiresImmediateRefresh: true)
        case "v2_conversation_states", "v2_group_announcements",
             "v2_group_permission_revisions", "v2_group_role_policies", "v2_group_role_policy_baselines",
             "v2_direct_sending_capabilities", "v2_member_administration_intents",
             "v2_membership_intents", "v2_group_capability_intents":
            return .init(scopes: [.conversations, .conversationMetadata], requiresImmediateRefresh: true)
        case "v2_relationship_projections", "v2_social_operations", "v2_profile_invalidations":
            return .init(scopes: [.contacts, .conversations, .conversationDetails, .presentations], requiresImmediateRefresh: true)
        case "v2_account_preference_operations", "v2_read_receipt_preference", "v2_stranger_message_preference", "v2_user_add_preference":
            return .init(scopes: [.privacy, .conversationDetails], requiresImmediateRefresh: true)
        case "v2_user_block_projections", "v2_snapshots":
            return .all
        default:
            // A future projection must not silently become delayed or invisible.
            return .all
        }
    }
}
