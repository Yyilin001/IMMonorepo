import GRDB

extension GRDBV2LocalSyncStore {
    /// 订阅本地投影变更。
    ///
    /// 订阅会立即给出一次全量失效，因此打开页面时不需要依赖观察到订阅之前已经提交的事务。
    ///
    /// - Returns: 变更订阅句柄。
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
        pending = pending.merging(Self.change(table: event.tableName, kind: event.kind))
    }
    /// 事务提交后发布累积的变更。
    ///
    /// - Parameter db: 已提交的数据库。
    func databaseDidCommit(_ db: Database) {
        let committed = pending
        pending = .none
        hub.publish(committed)
    }
    /// 事务回滚后丢弃累积的变更。
    ///
    /// - Parameter db: 已回滚的数据库。
    func databaseDidRollback(_ db: Database) { pending = .none }

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
        case "v2_sync_rebuild_requests", "v2_sync_cursor", "v2_sync_events", "v2_group_events", "v2_group_event_cursors",
             "v2_hybrid_group_background_state", "v2_snapshot_import", "v2_reset_rollback",
             "v2_local_installation", "v2_push_intent", "v2_message_search_jobs", "v2_message_search_state", "v2_message_effects", "v2_reaction_versions", "v2_reaction_effects", "v2_announcement_effects", "v2_pin_effects", "v2_role_policy_effects":
            return .none
        // Derived summary rows may be deleted/reinserted for an ordinary new
        // message. Their source projection separately raises urgent changes.
        case "v2_conversation_list_entries", "v2_conversation_summaries":
            return .init(scopes: .conversations, requiresImmediateRefresh: false)
        case "v2_message_projections", "v2_room_profile_projections", "v2_direct_room_profile_projections", "v2_direct_room_identities":
            return .init(scopes: conversation, requiresImmediateRefresh: kind != .insert)
        case "v2_profile_views":
            return .init(scopes: [.contacts, .conversations, .conversationDetails], requiresImmediateRefresh: kind != .insert)
        case "v2_role_policy_recovery_requests":
            return .init(scopes: .conversationDetails, requiresImmediateRefresh: false)
        case "v2_message_reactions", "v2_direct_read_receipt_projections", "v2_pending_message_reactions", "v2_pending_read_receipts":
            return .init(scopes: .conversationDetails, requiresImmediateRefresh: false)
        case "v2_pending_message_commands", "v2_pending_forward_messages", "v2_forward_message_plans", "v2_forward_message_chunks", "v2_pending_group_room_creations":
            return .init(scopes: conversation, requiresImmediateRefresh: false)
        case "v2_conversation_states", "v2_pending_conversation_states", "v2_message_favorites", "v2_pending_message_favorites",
             "v2_group_announcements", "v2_group_pinned_messages", "v2_pending_group_capabilities",
             "v2_message_tombstones", "v2_moderation_projections", "v2_room_control_projections",
             "v2_room_event_authorizations", "v2_group_member_roles", "v2_group_permission_revisions", "v2_group_role_policies", "v2_group_role_policy_baselines",
             "v2_direct_sending_capabilities", "v2_timeline_activity_projections", "v2_pending_message_edits",
             "v2_pending_message_redactions", "v2_pending_message_withdrawals", "v2_pending_member_mutes",
             "v2_pending_membership_commands", "v2_pending_moderated_member_removals":
            return .init(scopes: conversation, requiresImmediateRefresh: true)
        case "v2_relationship_projections", "v2_pending_social_commands", "v2_profile_invalidations":
            return .init(scopes: [.contacts, .conversations, .conversationDetails], requiresImmediateRefresh: true)
        case "v2_read_receipt_preference", "v2_stranger_message_preference", "v2_user_add_preference":
            return .init(scopes: [.privacy, .conversationDetails], requiresImmediateRefresh: true)
        case "v2_user_block_projections", "v2_snapshots":
            return .all
        default:
            // A future projection must not silently become delayed or invisible.
            return .all
        }
    }
}
