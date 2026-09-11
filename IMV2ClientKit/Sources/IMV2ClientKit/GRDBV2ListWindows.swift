import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore {
    /// 构造关系列表的作用域与搜索筛选条件。
    ///
    /// 查询文本需不超过 100 字节；分词后单字符为空即视为非法输入。
    /// 单字符查询使用单字索引，多字符查询使用相邻双字词元短语匹配，
    /// 并返回是否需要联结资料视图与全文索引。
    ///
    /// - Parameters:
    ///   - scope: 关系分页作用域（已接受、收到请求、发出请求）。
    ///   - query: 可选的展示名或账号名搜索文本。
    /// - Returns: SQL 条件、绑定参数与可选的搜索联结片段。
    /// - Throws: 查询文本过长或分词结果非法时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    static func relationshipListSelection(scope: V2ClientRelationshipPageScope, matching query: String?) throws -> (clauses: [String], arguments: StatementArguments, searchJoin: String) {
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedQuery.utf8.count <= 100 else { throw V2ClientProjectionError.invalidMessagePayload }
        let searchTokens = V2CharacterGramTokenizer().tokenize(trimmedQuery)
        guard trimmedQuery.isEmpty || !searchTokens.unigrams.isEmpty else {
            throw V2ClientProjectionError.invalidMessagePayload
        }

        var clauses: [String] = []
        var arguments: StatementArguments = []
        switch scope {
        case .accepted:
            clauses.append("relationship.state = ?")
            arguments += [V2RelationshipState.accepted.rawValue]
        case .incomingRequests(let currentUserID):
            clauses.append("relationship.state = ? AND relationship.requested_by_user_id <> ?")
            arguments += [V2RelationshipState.pending.rawValue, currentUserID.rawValue]
        case .outgoingRequests(let currentUserID):
            clauses.append("relationship.state = ? AND relationship.requested_by_user_id = ?")
            arguments += [V2RelationshipState.pending.rawValue, currentUserID.rawValue]
        }
        if !trimmedQuery.isEmpty {
            let match: String
            if searchTokens.characterCount == 1 {
                match = "display_unigrams : \(searchTokens.unigrams[0]) OR handle_unigrams : \(searchTokens.unigrams[0])"
            } else {
                let phrase = "\"\(searchTokens.bigrams.joined(separator: " "))\""
                match = "display_bigrams : \(phrase) OR handle_bigrams : \(phrase)"
            }
            clauses.append("v2_contact_profile_search MATCH ?")
            arguments += [match]
        }
        let searchJoin = trimmedQuery.isEmpty
            ? ""
            : "JOIN v2_profile_views AS profile ON profile.user_id = relationship.target_user_id JOIN v2_contact_profile_search ON v2_contact_profile_search.rowid = profile.rowid"
        return (clauses, arguments, searchJoin)
    }

    /// 以锚点为中心读取关系列表窗口。
    ///
    /// 先按锚点定位当前位置（锚点已不存在时退回使用传入游标），再分别向更早与更晚两个方向
    /// 执行有界键集查询，最终合成包含锚点前若干条与后续一页的窗口。
    ///
    /// - Parameters:
    ///   - scope: 关系分页作用域。
    ///   - query: 可选的搜索文本。
    ///   - anchor: 锚点游标。
    ///   - limit: 窗口内最多返回的条目数，需落在 `1...500`。
    ///   - precedingCount: 锚点之前保留的条目数，需小于 `limit`。
    /// - Returns: 关系列表窗口。
    /// - Throws: 分页参数越界或查询文本非法时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``；数据库读取失败时抛出底层错误。
    public func relationshipWindow(
        scope: V2ClientRelationshipPageScope, matching query: String? = nil,
        around anchor: V2ClientRelationshipCursor, limit: Int = 200, precedingCount: Int = 50
    ) throws -> V2ClientRelationshipWindow {
        guard (1...500).contains(limit), (0..<limit).contains(precedingCount) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let selection = try Self.relationshipListSelection(scope: scope, matching: query)
        return try databasePool.read { db in
            let base = """
                SELECT relationship.target_user_id AS target_user_id, relationship.state, relationship.requested_by_user_id, relationship.updated_at AS updated_at
                FROM v2_relationship_projections AS relationship \(selection.searchJoin)
                WHERE \(selection.clauses.joined(separator: " AND "))
                """
            let current = try Row.fetchOne(db, sql: base + " AND relationship.target_user_id = ?", arguments: selection.arguments + [anchor.targetUserID.rawValue])
            let position = try current.map(Self.relationshipWindowCursor) ?? anchor
            let timestamp = position.updatedAt.timeIntervalSince1970
            let earlier = try Self.boundedKeysetRows(base: base, arguments: selection.arguments, branches: [
                ("relationship.updated_at > ?", [timestamp]),
                ("relationship.updated_at = ? AND relationship.target_user_id < ?", [timestamp, position.targetUserID.rawValue])
            ], order: "updated_at ASC, target_user_id DESC", limit: limit + 1, db: db)
            let later = try Self.boundedKeysetRows(base: base, arguments: selection.arguments, branches: [
                ("relationship.updated_at < ?", [timestamp]),
                ("relationship.updated_at = ? AND relationship.target_user_id >= ?", [timestamp, position.targetUserID.rawValue])
            ], order: "updated_at DESC, target_user_id ASC", limit: limit + 1, db: db)
            let window = Self.listWindowRows(earlier: earlier, later: later, limit: limit, precedingCount: precedingCount)
            let relationships = try window.rows.map(Self.decodeRelationshipProjection)
            let next = try window.hasLater ? window.rows.last.map(Self.relationshipWindowCursor) : nil
            let resolved = try (later.first ?? earlier.first).map(Self.relationshipWindowCursor)
            return .init(page: .init(relationships: relationships, nextCursor: next, totalCount: nil), anchor: resolved, hasEarlier: window.hasEarlier)
        }
    }

    /// 由数据行构造关系游标。
    ///
    /// - Parameter row: 关系投影行。
    /// - Returns: 关系游标。
    /// - Throws: 字段缺失或类型不符时抛出。
    private static func relationshipWindowCursor(_ row: Row) throws -> V2ClientRelationshipCursor {
        try .init(updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double), targetUserID: .init(row["target_user_id"] as String))
    }

    /// 以锚点为中心读取会话列表窗口（区分是否归档）。
    ///
    /// 排序键为「置顶标记、最近活跃时间、房间标识」三元组，
    /// 因此置顶会话始终排在非置顶会话之前，且同一活跃时间下按房间标识稳定排序。
    ///
    /// - Parameters:
    ///   - isArchived: 是否查询归档列表。
    ///   - anchor: 锚点游标。
    ///   - limit: 窗口内最多返回的条目数，需落在 `1...500`。
    ///   - precedingCount: 锚点之前保留的条目数，需小于 `limit`。
    /// - Returns: 会话列表窗口。
    /// - Throws: 分页参数越界时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``；数据库读取失败时抛出底层错误。
    public func conversationListWindow(
        isArchived: Bool, around anchor: V2ClientConversationListCursor,
        limit: Int = 200, precedingCount: Int = 50
    ) throws -> V2ClientConversationListWindow {
        guard (1...500).contains(limit), (0..<limit).contains(precedingCount) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try databasePool.read { db in
            let current = try Row.fetchOne(db, sql: "SELECT room_id, last_activity, is_pinned FROM v2_conversation_list_entries WHERE room_id = ? AND is_archived = ?", arguments: [anchor.roomID.rawValue, isArchived])
            let position = try current.map(Self.conversationWindowCursor) ?? anchor
            let base = "SELECT room_id, last_activity, is_pinned, is_archived, mute_until FROM v2_conversation_list_entries WHERE is_archived = ?"
            let earlier = try Self.boundedKeysetRows(base: base, arguments: [isArchived], branches: [
                ("is_pinned > ?", [position.isPinned]),
                ("is_pinned = ? AND last_activity > ?", [position.isPinned, position.lastActivity.timeIntervalSince1970]),
                ("is_pinned = ? AND last_activity = ? AND room_id < ?", [position.isPinned, position.lastActivity.timeIntervalSince1970, position.roomID.rawValue])
            ], order: "is_pinned ASC, last_activity ASC, room_id DESC", limit: limit + 1, db: db)
            let later = try Self.boundedKeysetRows(base: base, arguments: [isArchived], branches: [
                ("is_pinned < ?", [position.isPinned]),
                ("is_pinned = ? AND last_activity < ?", [position.isPinned, position.lastActivity.timeIntervalSince1970]),
                ("is_pinned = ? AND last_activity = ? AND room_id >= ?", [position.isPinned, position.lastActivity.timeIntervalSince1970, position.roomID.rawValue])
            ], order: "is_pinned DESC, last_activity DESC, room_id ASC", limit: limit + 1, db: db)
            let window = Self.listWindowRows(earlier: earlier, later: later, limit: limit, precedingCount: precedingCount)
            let entries = try Self.conversationListEntries(window.rows, db: db)
            let next = try window.hasLater ? window.rows.last.map(Self.conversationWindowCursor) : nil
            let resolved = try (later.first ?? earlier.first).map(Self.conversationWindowCursor)
            return .init(page: .init(entries: entries, nextCursor: next), anchor: resolved, hasEarlier: window.hasEarlier)
        }
    }

    /// 由数据行构造会话列表游标。
    ///
    /// - Parameter row: 会话列表行。
    /// - Returns: 会话游标。
    /// - Throws: 字段缺失或类型不符时抛出。
    private static func conversationWindowCursor(_ row: Row) throws -> V2ClientConversationListCursor {
        try .init(isPinned: row["is_pinned"], lastActivity: Date(timeIntervalSince1970: row["last_activity"] as Double), roomID: .init(row["room_id"] as String))
    }

    /// 执行有界键集查询并合并多个分支结果。
    ///
    /// 各比较分支单独发起范围检索以保持可用的索引，无论锚点在列表中多深，
    /// 进入外层合并的候选行始终是有界的。
    ///
    /// - Parameters:
    ///   - base: 基础查询（不含分支条件）。
    ///   - arguments: 基础查询的绑定参数。
    ///   - branches: 各分支的比较条件与其参数。
    ///   - order: 分支查询的排序子句。
    ///   - limit: 合并后最多返回的行数。
    ///   - db: 只读数据库。
    /// - Returns: 有序的候选行。
    /// - Throws: SQL 执行失败时抛出底层错误。
    static func boundedKeysetRows(
        base: String, arguments: StatementArguments,
        branches: [(String, StatementArguments)], order: String, limit: Int, db: Database
    ) throws -> [Row] {
        var mergedArguments = StatementArguments()
        let queries = branches.map { predicate, branchArguments in
            mergedArguments += arguments
            mergedArguments += branchArguments
            mergedArguments += [limit]
            return "SELECT * FROM (\(base) AND (\(predicate)) ORDER BY \(order) LIMIT ?)"
        }
        mergedArguments += [limit]
        return try Row.fetchAll(db, sql: "SELECT * FROM (\(queries.joined(separator: " UNION ALL "))) ORDER BY \(order) LIMIT ?", arguments: mergedArguments)
    }

    static func listWindowRows(earlier: [Row], later: [Row], limit: Int, precedingCount: Int) -> (rows: [Row], hasEarlier: Bool, hasLater: Bool) {
        var before = min(precedingCount, earlier.count)
        let after = min(limit - before, later.count)
        before = min(limit - after, earlier.count)
        return (Array(earlier.prefix(before).reversed()) + Array(later.prefix(after)), earlier.count > before, later.count > after)
    }

    static func conversationListEntries(_ pageRows: [Row], db: Database) throws -> [V2ClientConversationListEntry] {
        guard !pageRows.isEmpty else { return [] }
        let roomIDs = try pageRows.map { try RoomID($0["room_id"] as String) }
        let placeholders = Array(repeating: "?", count: roomIDs.count).joined(separator: ",")
        let roomArguments = StatementArguments(roomIDs.map(\.rawValue))

        let messageRows = try Row.fetchAll(
            db,
            sql: """
            SELECT message.*
            FROM v2_conversation_summaries AS summary
            INNER JOIN v2_message_projections AS message ON message.message_id = summary.message_id
            WHERE summary.room_id IN (\(placeholders))
            """,
            arguments: roomArguments
        )
        let messages = try Dictionary(uniqueKeysWithValues: messageRows.map { row -> (RoomID, V2ClientMessageProjection) in
            let message = try Self.decodeMessageProjection(row)
            return (message.roomID, message)
        })
        let profiles = try Dictionary(uniqueKeysWithValues: Row.fetchAll(
            db,
            sql: "SELECT source_event_id, room_id, title, owner_user_id, delivery_mode, delivery_authority, membership_revision, created_at FROM v2_room_profile_projections WHERE room_id IN (\(placeholders))",
            arguments: roomArguments
        ).map { row -> (RoomID, V2ClientRoomProfileProjection) in
            let profile = try Self.decodeRoomProfileProjection(row)
            return (profile.roomID, profile)
        })

        var directIdentities = try Dictionary(uniqueKeysWithValues: Row.fetchAll(
            db,
            sql: "SELECT room_id, target_user_id, public_handle, display_name, account_kind, updated_at FROM v2_direct_room_identities WHERE room_id IN (\(placeholders))",
            arguments: roomArguments
        ).map { row -> (RoomID, V2ClientDirectRoomIdentity) in
            let identity = try Self.decodeDirectRoomIdentity(row)
            return (identity.roomID, identity)
        })
        for row in try Row.fetchAll(
            db,
            sql: "SELECT room_id, target_user_id, public_handle, display_name, account_kind, updated_at FROM v2_direct_room_profile_projections WHERE room_id IN (\(placeholders))",
            arguments: roomArguments
        ) {
            let identity = try Self.decodeDirectRoomIdentity(row)
            directIdentities[identity.roomID] = identity
        }

        let directUserIDs = Array(Set(directIdentities.values.map(\.publicIdentity.userID))).sorted()
        var profileViews: [UserID: V2ProfileView] = [:]
        if !directUserIDs.isEmpty {
            let userPlaceholders = Array(repeating: "?", count: directUserIDs.count).joined(separator: ",")
            for row in try Row.fetchAll(
                db,
                sql: "SELECT user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id IN (\(userPlaceholders))",
                arguments: StatementArguments(directUserIDs.map(\.rawValue))
            ) {
                let profile = try Self.decodeProfileView(row)
                profileViews[profile.userID] = profile
            }
        }

        let entries = try pageRows.map { row -> V2ClientConversationListEntry in
            let roomID = try RoomID(row["room_id"] as String)
            let directIdentity = directIdentities[roomID]
            let muteUntil: Double = row["mute_until"]
            return .init(
                roomID: roomID,
                lastMessage: messages[roomID],
                roomProfile: profiles[roomID],
                directIdentity: directIdentity,
                directProfileView: directIdentity.flatMap { profileViews[$0.publicIdentity.userID] },
                lastActivity: Date(timeIntervalSince1970: row["last_activity"] as Double),
                isPinned: row["is_pinned"],
                isArchived: row["is_archived"],
                muteUntil: muteUntil == 0 ? nil : Date(timeIntervalSince1970: muteUntil)
            )
        }
        return entries
    }
}
