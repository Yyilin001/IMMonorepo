import Foundation
import GRDB
import IMV2Core

public struct V2ClientFavoriteMessageCursor: Equatable, Sendable {
    public let updatedAt: Date
    public let messageID: MessageID

    public init(updatedAt: Date, messageID: MessageID) {
        self.updatedAt = updatedAt
        self.messageID = messageID
    }
}

public struct V2ClientFavoriteMessagePage: Equatable, Sendable {
    public let messages: [V2ClientMessageProjection]
    public let nextCursor: V2ClientFavoriteMessageCursor?

    public init(messages: [V2ClientMessageProjection], nextCursor: V2ClientFavoriteMessageCursor?) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public struct V2ClientConversationListCursor: Equatable, Sendable {
    public let isPinned: Bool
    public let lastActivity: Date
    public let roomID: RoomID

    public init(isPinned: Bool, lastActivity: Date, roomID: RoomID) {
        self.isPinned = isPinned
        self.lastActivity = lastActivity
        self.roomID = roomID
    }
}

/// 由单次 SQLite 读取快照组装出的有界会话列表行。
///
/// 可变的资料展示与持久房间身份保持分离，同时可见页面所需的全部取值都在本次读取中取齐，
/// 无需为每个房间追加一次查询。
public struct V2ClientConversationListEntry: Equatable, Sendable {
    public let roomID: RoomID
    public let lastMessage: V2ClientMessageProjection?
    public let latestVisible: V2RoomLatestVisible?
    public let roomProfile: V2ClientRoomProfileProjection?
    public let directIdentity: V2ClientDirectRoomIdentity?
    public let directProfileView: V2ProfileView?
    public let lastActivity: Date
    public let isPinned: Bool
    public let isArchived: Bool
    public let muteUntil: Date?

    public init(
        roomID: RoomID,
        lastMessage: V2ClientMessageProjection?,
        roomProfile: V2ClientRoomProfileProjection?,
        directIdentity: V2ClientDirectRoomIdentity?,
        directProfileView: V2ProfileView?,
        lastActivity: Date,
        isPinned: Bool,
        isArchived: Bool,
        muteUntil: Date?,
        latestVisible: V2RoomLatestVisible? = nil
    ) {
        precondition(lastMessage == nil || lastMessage?.roomID == roomID)
        precondition(roomProfile == nil || roomProfile?.roomID == roomID)
        precondition(directIdentity == nil || directIdentity?.roomID == roomID)
        self.roomID = roomID
        self.lastMessage = lastMessage
        self.latestVisible = latestVisible
        self.roomProfile = roomProfile
        self.directIdentity = directIdentity
        self.directProfileView = directProfileView
        self.lastActivity = lastActivity
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.muteUntil = muteUntil
    }
}

public struct V2ClientConversationListPage: Equatable, Sendable {
    public let entries: [V2ClientConversationListEntry]
    public let nextCursor: V2ClientConversationListCursor?

    public init(entries: [V2ClientConversationListEntry], nextCursor: V2ClientConversationListCursor?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// 本地同步存储。
///
/// 本地数据库是权威的设备端投影，它在单个 SQLite 事务内增量应用同步记录。
public actor GRDBV2LocalSyncStore: V2LocalSyncStore, V2LocalGroupEventStore, V2ClientProfileProjectionStore {
    /// 全部本地命令仓储共用的 actor 级连接池。
    ///
    /// 扩展方法保持 actor 边界，同时让各个持久化队列各自位于独立源文件中。
    let databasePool: DatabasePool
    let projectionChangeHub = V2ProjectionChangeHub()
    /// 搜索使用刻意独立可写的派生数据库。
    ///
    /// 这样可以避免全文检索维护与 `databasePool` 中的权威同步投影写入相互争用。
    let messageSearchDatabasePool: DatabasePool
    let databaseURL: URL
    let messageSearchDatabaseURL: URL

    init(databaseURL: URL, installationBinding: V2LocalInstallationBinding, userID: UserID? = nil) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: directory)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            db.add(function: Self.contactSearchUnigramsFunction)
            db.add(function: Self.contactSearchBigramsFunction)
        }
        databasePool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        messageSearchDatabaseURL = V2LocalDatabaseArtifacts(primary: databaseURL).search
        var openedSearchPool: DatabasePool?
        do {
            try databasePool.write { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
            try Self.migrator.migrate(databasePool)
            try databasePool.read { try Self.validateCurrentResourceSchema($0) }
            let searchPool = try DatabasePool(path: messageSearchDatabaseURL.path, configuration: configuration)
            openedSearchPool = searchPool
            try searchPool.write { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
            try Self.messageSearchMigrator.migrate(searchPool)
            try databasePool.write { db in
                try Self.establishInstallationBinding(installationBinding, userID: userID, db: db)
            }
            try Self.applyBackupExclusion(databaseURL: databaseURL)
            try Self.applyBackupExclusion(databaseURL: messageSearchDatabaseURL)
            messageSearchDatabasePool = searchPool
            let hub = projectionChangeHub
            try databasePool.write { db in
                db.add(transactionObserver: V2ProjectionTransactionObserver(hub: hub), extent: .databaseLifetime)
            }
        } catch {
            // Bootstrap may erase an untrusted installation after this throws.
            // Explicitly close both handles before allowing that fallback.
            try openedSearchPool?.close()
            try databasePool.close()
            throw error
        }
    }

    /// Opens only an existing, previously bound database. No migration, repair,
    /// search indexing, directory creation, binding write or presentation lease restoration.
    init(localReadOnlyDatabaseURL databaseURL: URL, installationBinding: V2LocalInstallationBinding, userID: UserID) throws {
        self.databaseURL = databaseURL
        messageSearchDatabaseURL = V2LocalDatabaseArtifacts(primary: databaseURL).search
        var configuration = Configuration()
        configuration.readonly = true
        let primary = try DatabasePool(path: databaseURL.path, configuration: configuration)
        do {
            try primary.read { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1"),
                      (row["binding"] as String) == installationBinding.value.uuidString,
                      (row["user_id"] as String?) == userID.rawValue else {
                    throw V2OfflineReadBootstrapError.installationBindingMismatch
                }
                try Self.validateCurrentResourceSchema(db)
            }
            // The required stored property remains read-only too. If no derived search
            // file exists, it points at the primary file; offline UI does not run search.
            let searchURL = FileManager.default.fileExists(atPath: messageSearchDatabaseURL.path)
                ? messageSearchDatabaseURL : databaseURL
            messageSearchDatabasePool = try DatabasePool(path: searchURL.path, configuration: configuration)
            databasePool = primary
        } catch { try? primary.close(); throw error }
    }

    /// 析构时结束变更订阅。
    ///
    /// 该过程发生在 actor 隔离且不在主线程上。GRDB 关闭会排空当前访问并拒绝后续访问，
    /// 包括仍持有该存储的滞后工作；任何错误都必须阻止调用方删除数据库文件。
    deinit { projectionChangeHub.finish() }

    public func close() throws {
        try databasePool.close()
        projectionChangeHub.finish()
        try messageSearchDatabasePool.close()
    }

    /// 在数据库重新打开后重申并校验「仅本机、不参与设备备份」策略。
    ///
    /// 受管目录、SQLite 文件、WAL 与 SHM 都被排除在设备备份之外，
    /// 因此备份无法恢复出尚未发送的 V2 命令。
    ///
    /// - Throws: 备份排除属性设置或校验失败时抛出。
    public func refreshBackupExclusion() throws {
        try Self.applyBackupExclusion(databaseURL: databaseURL)
        try Self.applyBackupExclusion(databaseURL: messageSearchDatabaseURL)
    }

    private static func applyBackupExclusion(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try V2LocalBackupExclusion.apply(to: directory)
        for artifact in [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")] where FileManager.default.fileExists(atPath: artifact.path) {
            try V2LocalBackupExclusion.apply(to: artifact)
        }
    }

    private static let contactSearchUnigramsFunction = DatabaseFunction(
        "v2_contact_search_unigrams",
        argumentCount: 1,
        pure: true
    ) { values in
        guard let value = String.fromDatabaseValue(values[0]) else { return "" }
        return V2CharacterGramTokenizer().tokenize(value).unigrams.joined(separator: " ")
    }

    private static let contactSearchBigramsFunction = DatabaseFunction(
        "v2_contact_search_bigrams",
        argumentCount: 1,
        pure: true
    ) { values in
        guard let value = String.fromDatabaseValue(values[0]) else { return "" }
        return V2CharacterGramTokenizer().tokenize(value).bigrams.joined(separator: " ")
    }

    public func boundAccountID() throws -> UserID? {
        try databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1").map(UserID.init)
        }
    }

    public func boundInstallationBinding() throws -> V2LocalInstallationBinding {
        try databasePool.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT binding FROM v2_local_installation WHERE singleton=1"), let id = UUID(uuidString:value) else {throw V2ClientLocalStorageError.installationBindingMismatch}
            return .init(value:id)
        }
    }

    public func cursor() throws -> V2LocalSyncCursor? {
        try databasePool.read { db in try Self.readCursor(db) }
    }

    /// 持久化一次恢复意图，但不擦除当前投影库与任何发件箱。
    ///
    /// - Throws: 数据库写入失败时抛出。
    public func requestSnapshotRebuild() throws {
        try databasePool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO v2_sync_rebuild_requests (singleton) VALUES (1)")
        }
    }

    public func requiresSnapshotRebuild() throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_sync_rebuild_requests)") == true
        }
    }

    public func discardSyncCapabilities(generation: UInt64) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db), cursor.state == .ready else {
                throw V2ClientSyncError.resetPending
            }
            guard cursor.generation == generation else {
                throw V2ClientSyncError.generationMismatch
            }
            try Self.writeCursor(try .init(
                state: .ready,
                generation: generation,
                appliedSequence: cursor.appliedSequence,
                serverAcknowledgedSequence: cursor.serverAcknowledgedSequence,
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            ), db: db)
        }
    }

    public func groupEventCursor(roomID: RoomID) throws -> UInt64 {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT applied_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [roomID.rawValue]
            ) else { return 0 }
            return try Self.storageUnsigned(row, column: "applied_room_sequence")
        }
    }

    /// Only the room-page apply transaction's durable cursor is progress evidence.
    /// Projection maxima and directory/latest-visible heads cannot replace it.
    /// An unresolved trimmed-history gap is deliberately not advertised as C.
    public func roomProgressAppliedSequence(roomID: RoomID) throws -> UInt64? {
        try databasePool.read { db in
            if try Bool.fetchOne(db, sql: "SELECT activation_prepared FROM v2_snapshot_import LIMIT 1") == true { return nil }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT cursor.applied_room_sequence
                FROM v2_group_event_cursors AS cursor
                WHERE cursor.room_id = ? AND cursor.history_incomplete = 0
                  AND NOT EXISTS (SELECT 1 FROM v2_room_membership_states WHERE room_id = cursor.room_id AND is_member = 0)
                  AND NOT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = cursor.room_id AND is_group_event_authorized = 0)
                  AND NOT EXISTS (SELECT 1 FROM v2_room_event_authorizations WHERE room_id = cursor.room_id AND is_authorized = 0)
                """, arguments: [roomID.rawValue]) else { return nil }
            return try Self.storageUnsigned(row, column: "applied_room_sequence")
        }
    }

    /// 该房间在服务端被裁剪掉的历史下界。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 已裁剪的历史下界；零表示从未裁剪。
    /// - Throws: 本地读取失败时抛出。
    public func roomLogTrimmedThroughSequence(roomID: RoomID) throws -> UInt64 {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT log_trimmed_through_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [roomID.rawValue]
            ) else { return 0 }
            return try Self.storageUnsigned(row, column: "log_trimmed_through_room_sequence")
        }
    }

    /// 本地是否已确认该房间缺失历史。
    ///
    /// 标记在"本页之前本地序号低于服务端裁剪下界"的那一刻置位并永久保留：那段历史已经
    /// 被服务端删除，不可能再补齐，界面必须显式告知用户，而不是假装历史完整。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 缺失历史时为 `true`。
    /// - Throws: 本地读取失败时抛出。
    public func roomLogHistoryIsIncomplete(roomID: RoomID) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT history_incomplete FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [roomID.rawValue]
            ) ?? false
        }
    }

    public func knownRoomLogRoomIDs(after roomID: RoomID?, limit: Int) throws -> [RoomID] {
        try roomLogRoomIDs(after: roomID, limit: limit)
    }

    private func roomLogRoomIDs(after roomID: RoomID?, limit: Int) throws -> [RoomID] {
        precondition(limit > 0 && limit <= 10_001)
        return try databasePool.read { db in
            let rawRoomIDs = try String.fetchAll(
                db,
                sql: """
                    WITH room_log_rooms AS (
                        SELECT room_id
                        FROM v2_room_profile_projections
                        WHERE is_group_event_authorized = 1
                        UNION
                        SELECT direct.room_id
                        FROM (
                            SELECT room_id FROM v2_direct_room_profile_projections
                            UNION
                            SELECT room_id FROM v2_direct_room_identities
                        ) AS direct
                        LEFT JOIN v2_room_event_authorizations AS authorization
                          ON authorization.room_id = direct.room_id
                        WHERE COALESCE(authorization.is_authorized, 1) = 1
                    )
                    SELECT room_id
                    FROM room_log_rooms
                    WHERE (? IS NULL OR room_id > ?)
                    ORDER BY room_id ASC
                    LIMIT ?
                    """,
                arguments: [roomID?.rawValue, roomID?.rawValue, limit]
            )
            return try rawRoomIDs.map(RoomID.init)
        }
    }

    /// Local presentation needs positive retained room authority and no explicit
    /// membership/room denial. Cached titles, messages or identities alone do not override a denial.
    public func roomAllowsLocalRead(roomID: RoomID) throws -> Bool {
        try databasePool.read { db in
            if try Bool.fetchOne(db, sql: "SELECT is_member = 0 FROM v2_room_membership_states WHERE room_id = ?", arguments: [roomID.rawValue]) == true { return false }
            if try Bool.fetchOne(db, sql: "SELECT is_authorized = 0 FROM v2_room_event_authorizations WHERE room_id = ?", arguments: [roomID.rawValue]) == true { return false }
            if let authorized = try Bool.fetchOne(db, sql: "SELECT is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) { return authorized }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM v2_direct_room_identities WHERE room_id = ? UNION ALL SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = ?)", arguments: [roomID.rawValue, roomID.rawValue]) == true
        }
    }

    public func isKnownRoomLogRoom(roomID: RoomID) throws -> Bool {
        try databasePool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM v2_room_profile_projections
                        WHERE room_id = ? AND is_group_event_authorized = 1
                        UNION ALL
                        SELECT 1
                        FROM (
                            SELECT room_id FROM v2_direct_room_profile_projections
                            UNION
                            SELECT room_id FROM v2_direct_room_identities
                        ) AS direct
                        LEFT JOIN v2_room_event_authorizations AS authorization
                          ON authorization.room_id = direct.room_id
                        WHERE direct.room_id = ? AND COALESCE(authorization.is_authorized, 1) = 1
                    )
                    """,
                arguments: [roomID.rawValue, roomID.rawValue]
            ) ?? false
        }
    }

    public func groupEventAccess(roomID: RoomID) throws -> V2ClientGroupEventAccess? {
        try databasePool.read { try Self.groupEventAccess(roomID: roomID, db: $0) }
    }

    static func groupEventAccess(roomID: RoomID, db: Database) throws -> V2ClientGroupEventAccess? {
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?",
            arguments: [roomID.rawValue]
        ) {
            return .init(
                isAuthorized: row["is_group_event_authorized"] as Bool
            )
        }
        if try Bool.fetchOne(db, sql: "SELECT is_member = 0 FROM v2_room_membership_states WHERE room_id = ?", arguments: [roomID.rawValue]) == true {
            return .init(isAuthorized: false)
        }
        let directKnown = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = ? UNION ALL SELECT 1 FROM v2_direct_room_identities WHERE room_id = ?)",
            arguments: [roomID.rawValue, roomID.rawValue]
        ) ?? false
        guard directKnown else { return nil }
        let authorized = try Bool.fetchOne(
            db,
            sql: "SELECT COALESCE((SELECT is_authorized FROM v2_room_event_authorizations WHERE room_id = ?), 1)",
            arguments: [roomID.rawValue]
        ) ?? true
        return .init(isAuthorized: authorized)
    }

    public func roomAppliedRoomSequence(roomID: RoomID) throws -> UInt64 {
        try databasePool.read { db in
            // Sparse invalid-value indexes check every source without scanning valid history.
            // Both validation and indexed maxima share this statement's read snapshot.
            guard let row = try Row.fetchOne(db, sql: """
                SELECT CASE WHEN EXISTS (
                    SELECT room_id FROM v2_group_event_cursors WHERE room_id = ? AND (typeof(applied_room_sequence) <> 'integer' OR applied_room_sequence < 0)
                    UNION ALL
                    SELECT room_id FROM v2_group_events WHERE room_id = ? AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_message_projections WHERE room_id = ? AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_reaction_versions WHERE room_id = ? AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_group_pinned_messages WHERE room_id = ? AND room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_group_announcements WHERE room_id = ? AND room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_group_role_policies WHERE room_id = ? AND room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_group_member_roles WHERE room_id = ? AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_group_avatar_invalidations WHERE room_id = ? AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                    UNION ALL
                    SELECT room_id FROM v2_group_nickname_invalidations WHERE room_id = ? AND (typeof(room_sequence) <> 'integer' OR room_sequence < 1)
                ) THEN NULL ELSE (
                    SELECT COALESCE(MAX(value), 0) FROM (
                        SELECT applied_room_sequence AS value FROM v2_group_event_cursors WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_events WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_message_projections WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_reaction_versions WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_pinned_messages WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_announcements WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_role_policies WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_member_roles WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_avatar_invalidations WHERE room_id = ?
                        UNION ALL
                        SELECT MAX(room_sequence) AS value FROM v2_group_nickname_invalidations WHERE room_id = ?
                    )
                ) END AS value
                """, arguments: StatementArguments(Array(repeating: roomID.rawValue, count: 20))) else {
                throw V2ClientSyncError.storageRangeExceeded
            }
            return try Self.storageUnsigned(row, column: "value")
        }
    }

    public func markRoomEventUnauthorized(roomID: RoomID) throws {
        try databasePool.write { try Self.markRoomEventUnauthorized(roomID: roomID, db: $0) }
    }

    static func markRoomEventUnauthorized(roomID: RoomID, db: Database) throws {
        try Self.requireProjectionWritesUnfenced(db: db)
        try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue])
        try db.execute(sql: "DELETE FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [roomID.rawValue])
        try db.execute(
            sql: "UPDATE v2_room_profile_projections SET is_group_event_authorized = 0 WHERE room_id = ?",
            arguments: [roomID.rawValue]
        )
        try db.execute(
            sql: """
                INSERT INTO v2_room_event_authorizations (room_id, is_authorized)
                SELECT ?, 0
                WHERE EXISTS (
                    SELECT 1 FROM v2_direct_room_profile_projections WHERE room_id = ?
                    UNION ALL
                    SELECT 1 FROM v2_direct_room_identities WHERE room_id = ?
                )
                ON CONFLICT(room_id) DO UPDATE SET is_authorized = excluded.is_authorized
                """,
            arguments: [roomID.rawValue, roomID.rawValue, roomID.rawValue]
        )
    }

    public func applyGroupEventPage(_ page: V2ClientGroupEventPage) throws -> UInt64 {
        try applyGroupEventPageReportingChanges(page).appliedThrough
    }

    public func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) throws -> V2GroupEventPageCommit {
        try applyGroupEventPageReportingChanges(page, recoveryWork: nil)
    }

    /// Capture work again after committing state, before issuing the body request.
    public func applyRoomRecoveryPage(_ page: V2ClientGroupEventPage, work: V2RoomRecoveryWork) throws -> V2GroupEventPageCommit {
        guard page.roomID == work.roomID else { throw V2RoomRecoveryPersistenceError.invalidWork }
        return try applyGroupEventPageReportingChanges(page, recoveryWork: work)
    }

    private func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage, recoveryWork: V2RoomRecoveryWork?) throws -> V2GroupEventPageCommit {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            if let recoveryWork { try Self.requireRoomRecoveryPageAuthorization(recoveryWork, db: db) }
            let cursorRow = try Row.fetchOne(
                db,
                sql: "SELECT applied_room_sequence, log_trimmed_through_room_sequence FROM v2_group_event_cursors WHERE room_id = ?",
                arguments: [page.roomID.rawValue]
            )
            let cursor = try cursorRow.map { try Self.storageUnsigned($0, column: "applied_room_sequence") } ?? 0
            if let cursorRow { _ = try Self.storageUnsigned(cursorRow, column: "log_trimmed_through_room_sequence") }
            guard page.nextRoomSequence >= cursor,
                  zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence }),
                  (page.events.last?.roomSequence ?? cursor) <= page.nextRoomSequence,
                  !page.hasMore || page.nextRoomSequence > cursor
            else { throw V2ClientSyncError.invalidRecordOrdering }
            var insertedEvents = 0
            for event in page.events {
                if event.roomSequence <= cursor {
                    guard let existing = try Row.fetchOne(
                        db,
                        sql: "SELECT source_event_id, projection_kind, payload FROM v2_group_events WHERE room_id = ? AND room_sequence = ?",
                        arguments: [page.roomID.rawValue, try Self.storageInteger(event.roomSequence)]
                    ) else { throw V2ClientSyncError.invalidRecordOrdering }
                    let sourceEventID: String = existing["source_event_id"]
                    let projectionKind: String = existing["projection_kind"]
                    let payload: Data = existing["payload"]
                    guard sourceEventID == event.sourceEventID.rawValue, projectionKind == event.projectionKind, payload == event.payload else {
                        throw V2ClientSyncError.invalidRecordOrdering
                    }
                    continue
                }
                let record = try V2ClientSyncRecord(sequence: event.roomSequence, sourceEventID: event.sourceEventID, projectionKind: event.projectionKind, payload: event.payload)
                try Self.applyRoomEventProjection(record, roomID: page.roomID, db: db)
                try db.execute(
                    sql: "INSERT INTO v2_group_events (room_id, room_sequence, source_event_id, projection_kind, payload) VALUES (?, ?, ?, ?, ?)",
                    arguments: [page.roomID.rawValue, try Self.storageInteger(event.roomSequence), event.sourceEventID.rawValue, event.projectionKind, event.payload]
                )
                insertedEvents += 1
            }
            // 缺口判定使用本事务开头验证过的游标：本页之前本地只应用到 cursor，
            // 服务端已裁剪至 trimmed；若它超过旧游标，两者之间就是永久缺口。
            let trimmedThrough = try Self.storageInteger(page.logTrimmedThroughRoomSequence)
            let hasGap = page.logTrimmedThroughRoomSequence > cursor
            try db.execute(
                sql: """
                    INSERT INTO v2_group_event_cursors
                        (room_id, applied_room_sequence, log_trimmed_through_room_sequence, history_incomplete)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(room_id) DO UPDATE SET
                        applied_room_sequence = excluded.applied_room_sequence,
                        -- 下界只增不减：服务端裁剪过的历史不会因为一次旧响应而"变完整"。
                        log_trimmed_through_room_sequence = MAX(
                            v2_group_event_cursors.log_trimmed_through_room_sequence,
                            excluded.log_trimmed_through_room_sequence
                        ),
                        -- 缺口是永久的：标记一旦置位就保持置位。
                        history_incomplete = MAX(
                            v2_group_event_cursors.history_incomplete,
                            excluded.history_incomplete
                        )
                    """,
                arguments: [
                    page.roomID.rawValue,
                    try Self.storageInteger(page.nextRoomSequence),
                    trimmedThrough,
                    hasGap ? 1 : 0
                ]
            )
            if let recoveryWork {
                if try !Self.finishRoomRecoveryWork(recoveryWork, db: db) {
                    try Self.recordRoomRecoveryService(recoveryWork, db: db)
                }
            }
            return try .init(appliedThrough: page.nextRoomSequence, insertedEventCount: insertedEvents)
        }
    }

    public func apply(_ batch: V2ClientSyncBatch) throws -> V2LocalSyncCursor {
        try databasePool.write { db in
            try Self.validatePersistable(batch)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_sync_rebuild_requests)") == false else { throw V2ClientSyncError.snapshotRebuildRequired }
            var cursor = try Self.readCursor(db) ?? .init(
                state: .ready,
                generation: batch.generation,
                appliedSequence: 0,
                serverAcknowledgedSequence: 0,
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            guard cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            guard cursor.generation == batch.generation else { throw V2ClientSyncError.generationMismatch }
            try Self.validateOrdering(batch.records)
            var applied = cursor.appliedSequence
            for record in batch.records {
                if record.sequence <= applied {
                    guard try Self.matchesExisting(record, db: db) else { throw V2ClientSyncError.invalidRecordOrdering }
                    continue
                }
                guard record.sequence == applied + 1 else { throw V2ClientSyncError.invalidRecordOrdering }
                if try Self.isRevokedRoomRecord(record, db: db) {
                    // Keep the durable receipt below while discarding stale room-scoped content.
                } else if record.projectionKind == "relationship" {
                    try Self.applyRelationship(record, db: db)
                } else if record.projectionKind == "user_block" {
                    try Self.applyUserBlock(record, db: db)
                } else if record.projectionKind == "stranger_message_permission" {
                    try Self.applyStrangerMessagePermission(record, db: db)
                } else if record.projectionKind == "user_add_permission" {
                    try Self.applyUserAddPermission(record, db: db)
                } else if record.projectionKind == "live_activity_preferences" {
                    try Self.applyLiveActivityPreference(record,db:db)
                } else if record.projectionKind == "direct_read_receipt" {
                    try Self.applyDirectReadReceipt(record, db: db)
                } else if record.projectionKind == "own_read_watermark" {
                    try Self.applyOwnReadWatermark(record, db: db)
                } else if record.projectionKind == "read_receipt_preferences" {
                    try Self.applyReadReceiptPreference(record, db: db)
                } else if record.projectionKind == "conversation_state" {
                    try Self.persist(V2ClientConversationState(record: record), db: db)
                } else if record.projectionKind == "message_favorite" {
                    try Self.persist(V2ClientMessageFavorite(record: record), db: db)
                } else if record.projectionKind == "contact_alias" {
                    try Self.applyContactAliasInvalidation(record, db: db)
                } else if record.projectionKind == "room" || record.projectionKind == "membership" {
                    try Self.applyMembershipAwareRoomProjection(record, db: db)
                } else if record.projectionKind == "direct_room_profile" {
                    try Self.persist(V2ClientDirectRoomProfileProjection(record: record), db: db)
                } else if record.projectionKind == "timeline_activity" {
                    try Self.persist(V2ClientTimelineActivityProjection(record: record), db: db)
                } else if record.projectionKind == "direct_sending_capability" {
                    try Self.persist(V2ClientDirectSendingCapability(record: record), db: db)
                } else if record.projectionKind == "profile_invalidation" {
                    try Self.persist(V2ClientProfileInvalidation(record: record), db: db)
                }
                try db.execute(
                    sql: """
                    INSERT INTO v2_sync_events (sequence, source_event_id, projection_kind, payload)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [try Self.storageInteger(record.sequence), record.sourceEventID.rawValue, record.projectionKind, record.payload]
                )
                applied = record.sequence
            }
            // During ordinary delivery this is the new applied watermark. It
            // can be lower than `applied` only after a terminal reset rollback
            // cleared expired capabilities and the server is replaying facts
            // already present locally in bounded pages.
            let acknowledgementSequence = batch.records.last?.sequence ??
                cursor.pendingAcknowledgementSequence
            let needsAcknowledgement = acknowledgementSequence.map {
                $0 > cursor.serverAcknowledgedSequence
            } ?? false
            cursor = try .init(
                state: .ready,
                generation: cursor.generation,
                appliedSequence: applied,
                serverAcknowledgedSequence: cursor.serverAcknowledgedSequence,
                syncToken: batch.nextSyncToken,
                pendingAcknowledgementReceipt: needsAcknowledgement ? batch.receipt : nil,
                pendingAcknowledgementSequence: needsAcknowledgement ? acknowledgementSequence : nil,
                pendingReset: nil
            )
            try Self.writeCursor(cursor, db: db)
            return cursor
        }
    }

    public func markServerAcknowledged(generation: UInt64, sequence: UInt64, receipt: V2SyncReceipt) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db), cursor.state == .ready else { throw V2ClientSyncError.resetPending }
            guard cursor.generation == generation,
                  sequence == cursor.pendingAcknowledgementSequence,
                  receipt == cursor.pendingAcknowledgementReceipt
            else { throw V2ClientSyncError.acknowledgementReceiptMismatch }
            let updated = try V2LocalSyncCursor(
                state: .ready,
                generation: generation,
                appliedSequence: cursor.appliedSequence,
                serverAcknowledgedSequence: max(cursor.serverAcknowledgedSequence, sequence),
                syncToken: cursor.syncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            try Self.writeCursor(updated, db: db)
        }
    }

    public func beginReset(_ reset: V2ClientResetRequired) throws {
        try databasePool.write { db in
            let current = try Self.readCursor(db)
            if let current, current.state == .resetPending {
                guard current.pendingReset == reset else { throw V2ClientSyncError.resetFenceMismatch }
                return
            }
            let previous = try current ?? .init(
                state: .ready,
                generation: reset.generation.subtractingReportingOverflow(1).partialValue,
                appliedSequence: 0,
                serverAcknowledgedSequence: 0,
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            let nextGeneration = previous.generation.addingReportingOverflow(1)
            let rebuilding = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_sync_rebuild_requests)") == true
            guard !nextGeneration.overflow,
                  nextGeneration.partialValue == reset.generation || (rebuilding && reset.generation > previous.generation) else {
                throw V2ClientSyncError.generationMismatch
            }
            try db.execute(
                sql: """
                INSERT INTO v2_reset_rollback
                    (singleton, generation, applied_sequence, server_acknowledged_sequence)
                VALUES (1, ?, ?, ?)
                """,
                arguments: [
                    try Self.storageInteger(previous.generation),
                    try Self.storageInteger(previous.appliedSequence),
                    try Self.storageInteger(previous.serverAcknowledgedSequence),
                ]
            )
            try Self.writeCursor(try .init(
                state: .resetPending,
                generation: reset.generation,
                appliedSequence: previous.appliedSequence,
                serverAcknowledgedSequence: previous.serverAcknowledgedSequence,
                syncToken: previous.syncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: reset
            ), db: db)
        }
    }

    public func cancelReset(_ reset: V2ClientResetRequired) throws {
        try databasePool.write { db in
            guard let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == reset,
                  let rollback = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM v2_reset_rollback WHERE singleton = 1"
                  )
            else { throw V2ClientSyncError.resetFenceMismatch }
            let restored = try V2LocalSyncCursor(
                state: .ready,
                generation: try Self.storageUnsigned(rollback, column: "generation"),
                appliedSequence: try Self.storageUnsigned(rollback, column: "applied_sequence"),
                serverAcknowledgedSequence: try Self.storageUnsigned(rollback, column: "server_acknowledged_sequence"),
                // A reset can expire after the capabilities that preceded it.
                // Pull without either old capability and acknowledge bounded
                // duplicate pages until the server cursor catches up.
                syncToken: nil,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            )
            try Self.dropSnapshotShadowTables(db: db)
            try db.execute(sql: "DELETE FROM v2_snapshot_import")
            try db.execute(sql: "DELETE FROM v2_reset_rollback WHERE singleton = 1")
            try Self.writeCursor(restored, db: db)
        }
    }

    public func importedSnapshotManifest(for reset: V2ClientResetRequired) throws -> V2ClientSnapshotManifest? {
        try databasePool.read { db in
            guard let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == reset
            else { throw V2ClientSyncError.resetFenceMismatch }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT snapshot_id, generation, base_sequence, root_digest,
                       next_sync_token, receipt, capability_profile, page_count,
                       total_items, total_bytes
                FROM v2_snapshot_import
                WHERE snapshot_id = ?
                """,
                arguments: [reset.snapshotID.rawValue]
            ) else { return nil }
            guard (try Self.storageInteger(row, column: "generation")) == (try Self.storageInteger(reset.generation)),
                  (try Self.storageInteger(row, column: "base_sequence")) == (try Self.storageInteger(reset.baseSequence)),
                  let pageCount = Int(exactly: try Self.storageInteger(row, column: "page_count"))
            else { throw V2ClientSyncError.snapshotMismatch }
            return try .init(
                reset: reset,
                rootDigest: row["root_digest"],
                pageCount: pageCount,
                totalItems: Self.storageUnsigned(row, column: "total_items"),
                totalBytes: Self.storageUnsigned(row, column: "total_bytes"),
                nextSyncToken: .init(row["next_sync_token"] as String),
                receipt: .init(row["receipt"] as String),
                capabilityProfile: row["capability_profile"]
            )
        }
    }

    public func beginSnapshotImport(_ manifest: V2ClientSnapshotManifest, initialDigest: String) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard initialDigest == V2SnapshotV3Digest.initial(
                    baseSequence: manifest.reset.baseSequence,
                    capabilityProfile: manifest.capabilityProfile
                  ),
                  let cursor = try Self.readCursor(db),
                  cursor.pendingReset == manifest.reset,
                  cursor.state == .resetPending
            else { throw V2ClientSyncError.resetFenceMismatch }

            if try Self.matchesSnapshotImport(manifest, db: db) {
                guard try Self.snapshotShadowTablesExist(db: db) else {
                    throw V2ClientSyncError.snapshotProjectionConflict
                }
                return
            }
            guard cursor.state == .resetPending,
                  try Row.fetchOne(db, sql: "SELECT 1 FROM v2_snapshot_import LIMIT 1") == nil
            else { throw V2ClientSyncError.snapshotMismatch }

            try Self.dropSnapshotShadowTables(db: db)
            try Self.dropRetiredSnapshotTables(db: db)
            try Self.createSnapshotShadowTables(db: db)
            try db.execute(
                sql: """
                INSERT INTO v2_snapshot_import
                    (snapshot_id, generation, base_sequence, root_digest,
                     next_sync_token, receipt, capability_profile, page_count,
                     total_items, total_bytes, rolling_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    manifest.reset.snapshotID.rawValue,
                    try Self.storageInteger(manifest.reset.generation),
                    try Self.storageInteger(manifest.reset.baseSequence),
                    manifest.rootDigest,
                    manifest.nextSyncToken.rawValue,
                    manifest.receipt.rawValue,
                    manifest.capabilityProfile,
                    manifest.pageCount,
                    try Self.storageInteger(manifest.totalItems),
                    try Self.storageInteger(manifest.totalBytes),
                    initialDigest,
                ]
            )
        }
    }

    public func nextSnapshotPageIndex(for manifest: V2ClientSnapshotManifest) throws -> Int {
        try databasePool.read { db in
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.pendingReset == manifest.reset,
                  cursor.state == .resetPending,
                  let row = try Row.fetchOne(
                    db,
                    sql: "SELECT next_page_index FROM v2_snapshot_import WHERE snapshot_id = ?",
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ),
                  let index = Int(exactly: try Self.storageInteger(row, column: "next_page_index")),
                  (0 ... manifest.pageCount).contains(index)
            else { throw V2ClientSyncError.snapshotMismatch }
            return index
        }
    }

    public func applySnapshotPage(_ page: V2ClientSnapshotPage, for manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == manifest.reset,
                  let state = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT next_page_index, rolling_digest, last_projection_kind,
                           last_entity_key, applied_items, applied_bytes
                    FROM v2_snapshot_import
                    WHERE snapshot_id = ?
                    """,
                    arguments: [manifest.reset.snapshotID.rawValue]
                  )
            else { throw V2ClientSyncError.snapshotMismatch }

            guard let expectedIndex = Int(exactly: try Self.storageInteger(state, column: "next_page_index"))
            else { throw V2ClientSyncError.storageRangeExceeded }
            let previousDigest: String = state["rolling_digest"]
            let lastKind: String? = state["last_projection_kind"]
            let lastEntity: String? = state["last_entity_key"]
            let appliedItems = try Self.storageInteger(state, column: "applied_items")
            let appliedBytes = try Self.storageInteger(state, column: "applied_bytes")
            guard expectedIndex >= 0, appliedItems >= 0, appliedBytes >= 0,
                  page.index == expectedIndex,
                  page.index < manifest.pageCount,
                  V2SnapshotV3Digest.page(page.payload) == page.digest
            else { throw V2ClientSyncError.snapshotMismatch }

            let decoded: V2SnapshotProjectionV3Page
            do { decoded = try V2SnapshotProjectionV3Codec.decode(page.payload) }
            catch { throw V2ClientSyncError.snapshotProjectionConflict }
            let followsPreviousPage: Bool
            switch (lastKind, lastEntity) {
            case (nil, nil):
                followsPreviousPage = true
            case let (.some(kind), .some(entity)):
                followsPreviousPage = try V2SnapshotProjectionKey(
                    projectionKind: kind,
                    entityKey: entity
                ) < decoded.firstKey
            default:
                followsPreviousPage = false
            }
            guard decoded.items.count == page.itemCount,
                  decoded.firstKey == page.firstKey,
                  decoded.lastKey == page.lastKey,
                  followsPreviousPage
            else { throw V2ClientSyncError.snapshotProjectionConflict }
            for item in decoded.items {
                guard item.sequence <= manifest.reset.baseSequence else {
                    throw V2ClientSyncError.snapshotProjectionConflict
                }
            }

            let nextDigest = V2SnapshotV3Digest.next(
                previous: previousDigest,
                pageIndex: UInt32(page.index),
                pageDigest: page.digest,
                firstKey: page.firstKey,
                lastKey: page.lastKey,
                itemCount: UInt32(page.itemCount)
            )
            guard let nextItemCount = Int64(exactly: decoded.items.count).flatMap({ appliedItems.addingReportingOverflow($0).overflow ? nil : appliedItems + $0 }),
                  let pageByteCount = Int64(exactly: page.payload.count),
                  !appliedBytes.addingReportingOverflow(pageByteCount).overflow
            else { throw V2ClientSyncError.storageRangeExceeded }
            let nextByteCount = appliedBytes + pageByteCount
            guard UInt64(nextItemCount) <= manifest.totalItems,
                  UInt64(nextByteCount) <= manifest.totalBytes
            else { throw V2ClientSyncError.snapshotProjectionConflict }

            for item in decoded.items {
                try Self.applySnapshotItem(item, db: db)
            }

            try db.execute(
                sql: """
                UPDATE v2_snapshot_import
                SET next_page_index = ?, rolling_digest = ?,
                    last_projection_kind = ?, last_entity_key = ?,
                    applied_items = ?, applied_bytes = ?
                WHERE snapshot_id = ? AND next_page_index = ?
                """,
                arguments: [
                    expectedIndex + 1,
                    nextDigest,
                    page.lastKey.projectionKind,
                    page.lastKey.entityKey,
                    nextItemCount,
                    nextByteCount,
                    manifest.reset.snapshotID.rawValue,
                    expectedIndex,
                ]
            )
            guard db.changesCount == 1 else { throw V2ClientSyncError.snapshotMismatch }
        }
    }

    public func activateAcknowledgedSnapshot(_ manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == manifest.reset,
                  try Row.fetchOne(db, sql: "SELECT 1 FROM v2_reset_rollback WHERE singleton = 1") != nil,
                  try Bool.fetchOne(
                    db,
                    sql: "SELECT activation_prepared FROM v2_snapshot_import WHERE snapshot_id = ?",
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ) == true
            else { throw V2ClientSyncError.snapshotMismatch }

            guard let state = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT next_page_index, rolling_digest, applied_items, applied_bytes
                    FROM v2_snapshot_import WHERE snapshot_id = ?
                    """,
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ),
                  (try Self.storageInteger(state, column: "next_page_index")) == Int64(manifest.pageCount),
                  (state["rolling_digest"] as String) == manifest.rootDigest,
                  UInt64(exactly: try Self.storageInteger(state, column: "applied_items")) == manifest.totalItems,
                  UInt64(exactly: try Self.storageInteger(state, column: "applied_bytes")) == manifest.totalBytes
            else { throw V2ClientSyncError.snapshotMismatch }

            // Every data-proportional copy, filter, derived-table rebuild and
            // index build completed before the server ACK. This transaction
            // performs a fixed number of schema renames plus the generation
            // fence; it does not scan projection rows or amplify them into WAL.
            let triggers = try Self.suspendApplicationTriggers(db: db)
            for table in Self.snapshotOrdinaryBankTables {
                try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(Self.snapshotRetiredTable(for: table))")
                try db.execute(sql: "ALTER TABLE \(Self.snapshotShadowTable(for: table)) RENAME TO \(table)")
            }
            try db.execute(
                sql: "ALTER TABLE v2_contact_profile_search RENAME TO \(Self.snapshotRetiredTable(for: "v2_contact_profile_search"))"
            )
            try db.execute(
                sql: "ALTER TABLE \(Self.snapshotShadowTable(for: "v2_contact_profile_search")) RENAME TO v2_contact_profile_search"
            )
            try Self.restoreApplicationTriggers(triggers, db: db)
            // Evidence was computed against verified shadows before ACK.
            // Only the indexed, quota-bounded send metadata changes here; no
            // projection scan is added to the fixed bank activation.
            try db.execute(sql: "UPDATE v2_message_send_operations SET accepted_projection_observed=1,projection_observed_snapshot_id=NULL WHERE projection_observed_snapshot_id=?",
                arguments: [manifest.reset.snapshotID.rawValue])

            try db.execute(
                sql: """
                INSERT INTO v2_snapshots
                    (singleton, snapshot_id, generation, base_sequence,
                     root_digest, next_sync_token, acknowledgement_receipt)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    snapshot_id = excluded.snapshot_id,
                    generation = excluded.generation,
                    base_sequence = excluded.base_sequence,
                    root_digest = excluded.root_digest,
                    next_sync_token = excluded.next_sync_token,
                    acknowledgement_receipt = excluded.acknowledgement_receipt
                """,
                arguments: [
                    manifest.reset.snapshotID.rawValue,
                    try Self.storageInteger(manifest.reset.generation),
                    try Self.storageInteger(manifest.reset.baseSequence),
                    manifest.rootDigest,
                    manifest.nextSyncToken.rawValue,
                    manifest.receipt.rawValue,
                ]
            )
            try Self.writeCursor(try .init(
                state: .ready,
                generation: manifest.reset.generation,
                appliedSequence: manifest.reset.baseSequence,
                serverAcknowledgedSequence: manifest.reset.baseSequence,
                syncToken: manifest.nextSyncToken,
                pendingAcknowledgementReceipt: nil,
                pendingAcknowledgementSequence: nil,
                pendingReset: nil
            ), db: db)
            try db.execute(sql: "DELETE FROM v2_sync_rebuild_requests")
            try db.execute(sql: "DELETE FROM v2_snapshot_import WHERE snapshot_id = ?", arguments: [manifest.reset.snapshotID.rawValue])
            try db.execute(sql: "DELETE FROM v2_reset_rollback WHERE singleton = 1")
        }
    }

    public func prepareSnapshotActivation(_ manifest: V2ClientSnapshotManifest) throws {
        try databasePool.write { db in
            try Self.validatePersistable(manifest)
            guard try Self.matchesSnapshotImport(manifest, db: db),
                  let cursor = try Self.readCursor(db),
                  cursor.state == .resetPending,
                  cursor.pendingReset == manifest.reset,
                  let state = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT next_page_index, rolling_digest, applied_items,
                           applied_bytes, activation_prepared
                    FROM v2_snapshot_import WHERE snapshot_id = ?
                    """,
                    arguments: [manifest.reset.snapshotID.rawValue]
                  ),
                  (try Self.storageInteger(state, column: "next_page_index")) == Int64(manifest.pageCount),
                  (state["rolling_digest"] as String) == manifest.rootDigest,
                  UInt64(exactly: try Self.storageInteger(state, column: "applied_items")) == manifest.totalItems,
                  UInt64(exactly: try Self.storageInteger(state, column: "applied_bytes")) == manifest.totalBytes
            else { throw V2ClientSyncError.snapshotMismatch }
            if state["activation_prepared"] as Bool { return }

            try Self.validateSnapshotMembershipFences(table: Self.snapshotShadowTable(for: "v2_room_membership_states"), db: db)
            try Self.persistAccountPreferenceFloors(db:db)
            try Self.prepareProfileSecurityFloorShadow(db: db)
            try Self.prepareDeviceOwnedIdentityShadow(db: db)
            // Direct-room eligibility is represented by the device identity
            // shadow, so it must be prepared (and invalidations applied)
            // before deciding which independent room-log cursors survive.
            try Self.preserveRoomLogProjection(inSnapshotShadows: db)
            let revokedRooms = try String.fetchCursor(db, sql: "SELECT room_id FROM \(Self.snapshotShadowTable(for: "v2_room_membership_states")) WHERE is_member = 0")
            while let roomID = try revokedRooms.next() {
                try Self.purgeRoomProjection(roomID: roomID, target: .snapshotShadow, db: db)
            }
            try Self.rebuildConversationSummaries(
                messages: Self.snapshotShadowTable(for: "v2_message_projections"),
                summaries: Self.snapshotShadowTable(for: "v2_conversation_summaries"),
                db: db
            )
            try Self.rebuildConversationListEntries(
                messages: Self.snapshotShadowTable(for: "v2_message_projections"),
                summaries: Self.snapshotShadowTable(for: "v2_conversation_summaries"),
                roomProfiles: Self.snapshotShadowTable(for: "v2_room_profile_projections"),
                directProfiles: Self.snapshotShadowTable(for: "v2_direct_room_profile_projections"),
                directIdentities: Self.snapshotShadowTable(for: "v2_direct_room_identities"),
                conversationStates: Self.snapshotShadowTable(for: "v2_conversation_states"),
                entries: Self.snapshotShadowTable(for: "v2_conversation_list_entries"),
                db: db
            )
            // Queue metadata work before ACK; activation only swaps this bank.
            // Descriptors stay in the authoritative message projection, never
            // in a second independently writable resource payload queue.
            try db.execute(sql: """
                INSERT OR REPLACE INTO \(Self.snapshotShadowTable(for: "v2_resource_projection_index_jobs"))
                    (message_id,room_id,queued_revision)
                SELECT message_id,room_id,message_revision FROM \(Self.snapshotShadowTable(for: "v2_message_projections"))
                WHERE media_ids<>'[]' AND is_withdrawn=0
                """)
            try Self.prepareContactSearchShadow(db: db)
            try Self.prepareMessageSearchControlShadow(db: db)
            try Self.createSnapshotShadowIndexes(db: db)
            try Self.prepareAcceptedSendSnapshotEvidence(snapshotID: manifest.reset.snapshotID.rawValue, db: db)
            try db.execute(
                sql: "UPDATE v2_snapshot_import SET activation_prepared = 1 WHERE snapshot_id = ?",
                arguments: [manifest.reset.snapshotID.rawValue]
            )
            guard db.changesCount == 1 else { throw V2ClientSyncError.snapshotMismatch }
        }
    }

    public func cleanupRetiredSnapshotTables() throws {
        try databasePool.write { db in
            guard try Self.readCursor(db)?.state == .ready else { return }
            try Self.dropRetiredSnapshotTables(db: db)
        }
    }

    private static let snapshotProjectionTables = [
        "v2_message_projections",
        "v2_message_tombstones",
        "v2_message_effects",
        "v2_message_reactions",
        "v2_reaction_versions",
        "v2_reaction_effects",
        "v2_moderation_projections",
        "v2_room_control_projections",
        "v2_room_profile_projections",
        "v2_room_membership_states",
        "v2_direct_room_profile_projections",
        "v2_direct_read_receipt_projections",
        "v2_room_read_watermarks",
        "v2_read_receipt_preference",
        "v2_profile_views",
        "v2_profile_invalidations",
        "v2_contact_alias_invalidations",
        "v2_relationship_projections",
        "v2_user_block_projections",
        "v2_stranger_message_preference",
        "v2_user_add_preference",
        "v2_live_activity_preference",
        "v2_conversation_states",
        "v2_message_favorites",
        "v2_timeline_activity_projections",
        "v2_direct_sending_capabilities",
        "v2_group_pinned_messages",
        "v2_pin_effects",
        "v2_group_announcements",
        "v2_announcement_effects",
        "v2_group_avatar_invalidations",
        "v2_group_avatar_effects",
        "v2_group_nickname_invalidations",
        "v2_group_nickname_effects",
        "v2_group_role_policies",
        "v2_group_role_policy_baselines",
        "v2_role_policy_effects",
        "v2_group_member_roles",
        "v2_member_effects",
        "v2_group_permission_revisions",
    ]

    /// 组成可原子替换的本地投影库的表集合。
    ///
    /// 设备自有的身份缓存会在应用权威失效后复制过去，而同步事件与搜索任务刻意从空开始。
    private static let snapshotOrdinaryBankTables = snapshotProjectionTables + [
        "v2_group_events",
        "v2_group_event_cursors",
        "v2_conversation_summaries",
        "v2_conversation_list_entries",
        "v2_direct_room_identities",
        "v2_sync_events",
        "v2_message_search_jobs",
        "v2_message_search_state",
        "v2_resource_projection_index_jobs",
    ]

    private static let snapshotVirtualBankTables = ["v2_contact_profile_search"]

    /// 在快照影子表中保留房间日志投影。
    ///
    /// 快照 V3 产物是用户同步流的规范基线，而房间日志历史拥有自己的持久化游标：
    /// 直接替换其行会让游标领先于可见投影。因此这里只保留仍出现在传入基线中的房间日志；
    /// 已被移出群或被吊销私聊身份的房间会丢弃本地事件历史，而不是借此获得新的读取权限。
    ///
    /// - Parameter db: 执行快照导入的数据库。
    /// - Throws: 查询或写入失败时抛出。
    private static func preserveRoomLogProjection(inSnapshotShadows db: Database) throws {
        let shadowRooms = snapshotShadowTable(for: "v2_room_profile_projections")
        let shadowDirectProfiles = snapshotShadowTable(for: "v2_direct_room_profile_projections")
        let shadowDirectIdentities = snapshotShadowTable(for: "v2_direct_room_identities")
        let shadowMessages = snapshotShadowTable(for: "v2_message_projections")
        let shadowTombstones = snapshotShadowTable(for: "v2_message_tombstones")
        let shadowReactions = snapshotShadowTable(for: "v2_message_reactions")
        let shadowModeration = snapshotShadowTable(for: "v2_moderation_projections")
        let shadowRoomControl = snapshotShadowTable(for: "v2_room_control_projections")
        let shadowTimeline = snapshotShadowTable(for: "v2_timeline_activity_projections")
        let shadowAnnouncements = snapshotShadowTable(for: "v2_group_announcements")
        let shadowRolePolicies = snapshotShadowTable(for: "v2_group_role_policies")
        let shadowMemberRoles = snapshotShadowTable(for: "v2_group_member_roles")
        let shadowPermissionRevisions = snapshotShadowTable(for: "v2_group_permission_revisions")
        // Preserve the independent room log for every currently authorized room.

        let authorizedRoomsSQL = """
                    SELECT room_id
                    FROM \(shadowRooms)
                    WHERE is_group_event_authorized = 1
                    UNION
                    SELECT direct.room_id
                    FROM (
                        SELECT room_id FROM \(shadowDirectProfiles)
                        UNION
                        SELECT room_id FROM \(shadowDirectIdentities)
                    ) AS direct
                    LEFT JOIN v2_room_event_authorizations AS authorization
                      ON authorization.room_id = direct.room_id
                    WHERE COALESCE(authorization.is_authorized, 1) = 1
            """
        func copyRoomRows(table: String, shadow: String, positiveSequence: String? = nil) throws {
            if let column = positiveSequence {
                if try Bool.fetchOne(db, sql: """
                    WITH room_log_rooms AS (\(authorizedRoomsSQL))
                    SELECT EXISTS (
                        SELECT 1 FROM (
                            SELECT \(column) AS value FROM \(shadow)
                            UNION ALL SELECT live.\(column) FROM \(table) AS live
                            JOIN room_log_rooms AS room ON room.room_id = live.room_id
                        ) WHERE typeof(value) <> 'integer' OR value <= 0
                    )
                    """) == true { throw V2ClientProjectionError.invalidMessagePayload }
            }
            try db.execute(sql: """
                WITH room_log_rooms AS (\(authorizedRoomsSQL))
                INSERT INTO \(shadow)
                SELECT live.*
                FROM \(table) AS live
                JOIN room_log_rooms AS room ON room.room_id = live.room_id
                ON CONFLICT DO NOTHING
                """)
        }

        if try Bool.fetchOne(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL))
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT room_sequence, timeline_sequence, message_revision FROM \(shadowMessages)
                    UNION ALL
                    SELECT live.room_sequence, live.timeline_sequence, live.message_revision
                    FROM v2_message_projections AS live JOIN authorized AS room ON room.room_id = live.room_id
                ) WHERE typeof(room_sequence) <> 'integer' OR room_sequence <= 0
                    OR typeof(timeline_sequence) <> 'integer' OR timeline_sequence < 0
                    OR typeof(message_revision) <> 'integer' OR message_revision <= 0
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try copyRoomRows(table: "v2_message_projections", shadow: shadowMessages)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT message_revision FROM \(shadowTombstones)
                    UNION ALL SELECT tombstone.message_revision FROM v2_message_tombstones AS tombstone
                    JOIN \(shadowMessages) AS message ON message.message_id = tombstone.message_id
                ) WHERE typeof(message_revision) <> 'integer' OR message_revision <= 1
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(shadowTombstones)
            SELECT tombstone.*
            FROM v2_message_tombstones AS tombstone
            JOIN \(shadowMessages) AS message ON message.message_id = tombstone.message_id
            ON CONFLICT DO NOTHING
            """)
        try preserveMessageEffectsInSnapshot(db: db)
        try preserveReactionStateInSnapshot(authorizedRoomsSQL: authorizedRoomsSQL, db: db)
        try preserveReactionEffectsInSnapshot(db: db)
        try db.execute(sql: "DELETE FROM \(shadowReactions)")
        try db.execute(sql: """
            INSERT INTO \(shadowReactions) (message_id, room_id, actor_user_id, reaction)
            SELECT state.message_id, state.room_id, state.actor_user_id, state.reaction
            FROM \(snapshotShadowTable(for: "v2_reaction_versions")) AS state
            WHERE state.action = 'add'
              AND NOT EXISTS (SELECT 1 FROM \(shadowTombstones) AS removed WHERE removed.message_id = state.message_id)
              AND NOT EXISTS (SELECT 1 FROM \(shadowMessages) AS message WHERE message.message_id = state.message_id AND message.is_withdrawn = 1)
            """)
        try copyRoomRows(table: "v2_moderation_projections", shadow: shadowModeration, positiveSequence: "room_sequence")
        try copyRoomRows(table: "v2_room_control_projections", shadow: shadowRoomControl, positiveSequence: "room_sequence")
        try copyRoomRows(table: "v2_timeline_activity_projections", shadow: shadowTimeline, positiveSequence: "timeline_sequence")
        try preservePinnedMessagesInSnapshot(db: db)
        try copyRoomRows(table: "v2_group_announcements", shadow: shadowAnnouncements)
        try preserveGroupAvatarInvalidations(authorizedRoomsSQL: authorizedRoomsSQL, db: db)
        try preserveGroupNicknameInvalidations(authorizedRoomsSQL: authorizedRoomsSQL, db: db)
        try preserveContactAliasInvalidations(db: db)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT revision, room_sequence FROM \(shadowAnnouncements)
                    UNION ALL SELECT revision, room_sequence FROM \(snapshotShadowTable(for: "v2_announcement_effects"))
                    UNION ALL SELECT effect.revision, effect.room_sequence FROM v2_announcement_effects AS effect
                    JOIN \(shadowAnnouncements) AS state ON state.room_id = effect.room_id
                ) WHERE typeof(revision) <> 'integer' OR revision <= 0
                    OR (room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence <= 0))
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(snapshotShadowTable(for: "v2_announcement_effects"))
            SELECT effect.* FROM v2_announcement_effects AS effect
            JOIN \(shadowAnnouncements) AS state ON state.room_id = effect.room_id
            WHERE effect.revision <= state.revision
              AND (effect.revision < state.revision OR
                   (effect.source_event_id = state.source_event_id AND effect.canonical_digest = state.canonical_digest))
            ON CONFLICT DO NOTHING
            """)
        let shadowPolicyBaselines = snapshotShadowTable(for: "v2_group_role_policy_baselines")
        // Validate candidates before membership comparisons can silently discard corruption.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_group_role_policy_baselines AS baseline
                JOIN v2_room_profile_projections AS live ON live.room_id = baseline.room_id
                JOIN \(shadowRooms) AS incoming ON incoming.room_id = baseline.room_id
                WHERE live.is_group_event_authorized = 1 AND incoming.is_group_event_authorized = 1
                  AND (typeof(baseline.permission_revision) <> 'integer' OR baseline.permission_revision <= 0
                    OR typeof(baseline.membership_revision) <> 'integer' OR baseline.membership_revision <= 0
                    OR typeof(baseline.room_sequence) <> 'integer' OR baseline.room_sequence < 0
                    OR typeof(live.membership_revision) <> 'integer' OR live.membership_revision <= 0
                    OR typeof(incoming.membership_revision) <> 'integer' OR incoming.membership_revision <= 0)
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(shadowPolicyBaselines)
            SELECT baseline.* FROM v2_group_role_policy_baselines AS baseline
            JOIN v2_room_profile_projections AS live ON live.room_id = baseline.room_id
            JOIN \(shadowRooms) AS incoming ON incoming.room_id = baseline.room_id
            WHERE live.is_group_event_authorized = 1 AND incoming.is_group_event_authorized = 1
              AND live.membership_revision = incoming.membership_revision AND live.source_event_id = incoming.source_event_id
              AND baseline.membership_revision <= incoming.membership_revision
            ON CONFLICT DO NOTHING
            """)
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM \(shadowRolePolicies) AS policy JOIN \(shadowPolicyBaselines) AS baseline ON baseline.room_id = policy.room_id
                WHERE policy.revision = baseline.permission_revision AND policy.permissions <>
                    CASE policy.role WHEN 'admin' THEN baseline.admin_permissions ELSE baseline.member_permissions END
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try preserveRolePoliciesInSnapshot(db: db)
        let shadowPolicyEffects = snapshotShadowTable(for: "v2_role_policy_effects")
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT revision, room_sequence FROM \(shadowPolicyEffects)
                    UNION ALL SELECT effect.revision, effect.room_sequence FROM v2_role_policy_effects AS effect
                    WHERE EXISTS (SELECT 1 FROM \(shadowRolePolicies) AS state
                        WHERE state.room_id = effect.room_id AND state.role = effect.role)
                       OR EXISTS (SELECT 1 FROM \(shadowPolicyBaselines) AS baseline WHERE baseline.room_id = effect.room_id)
                       OR EXISTS (SELECT 1 FROM \(shadowPolicyEffects) AS incoming
                        WHERE incoming.room_id = effect.room_id AND incoming.source_event_id = effect.source_event_id)
                ) WHERE typeof(revision) <> 'integer' OR revision <= 0
                    OR (room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence <= 0))
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_role_policy_effects AS live
                LEFT JOIN \(shadowRolePolicies) AS state ON state.room_id = live.room_id AND state.role = live.role
                LEFT JOIN \(shadowPolicyBaselines) AS baseline ON baseline.room_id = live.room_id
                JOIN \(shadowPolicyEffects) AS incoming ON incoming.source_event_id = live.source_event_id AND incoming.room_id = live.room_id
                WHERE live.revision <= MAX(COALESCE(state.revision, 0), COALESCE(baseline.permission_revision, 0)) AND (
                    live.role <> incoming.role OR live.revision <> incoming.revision OR live.canonical_digest <> incoming.canonical_digest
                    OR (live.room_sequence IS NOT NULL AND incoming.room_sequence IS NOT NULL AND live.room_sequence <> incoming.room_sequence)
                )
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(shadowPolicyEffects)
            SELECT effect.* FROM v2_role_policy_effects AS effect
            LEFT JOIN \(shadowRolePolicies) AS state ON state.room_id = effect.room_id AND state.role = effect.role
            LEFT JOIN \(shadowPolicyBaselines) AS baseline ON baseline.room_id = effect.room_id
            WHERE effect.revision <= MAX(COALESCE(state.revision, 0), COALESCE(baseline.permission_revision, 0))
              AND (effect.revision <= COALESCE(baseline.permission_revision, 0) OR effect.revision < state.revision OR
                   (effect.source_event_id = state.source_event_id AND effect.canonical_digest = state.canonical_digest))
            ON CONFLICT(source_event_id, room_id) DO UPDATE SET room_sequence = COALESCE(\(shadowPolicyEffects).room_sequence, excluded.room_sequence)
            """)
        let shadowMemberEffects = snapshotShadowTable(for: "v2_member_effects")
        // Validate source history before conflict joins and newest-member reduction.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT membership_revision, room_sequence, projection_sequence FROM \(shadowMemberEffects)
                    UNION ALL
                    SELECT live.membership_revision, live.room_sequence, live.projection_sequence
                    FROM v2_member_effects AS live
                    WHERE EXISTS (SELECT 1 FROM \(shadowRooms) AS room
                        WHERE room.room_id = live.room_id AND room.is_group_event_authorized = 1)
                       OR EXISTS (SELECT 1 FROM \(shadowMemberEffects) AS incoming
                        WHERE incoming.source_event_id = live.source_event_id)
                ) WHERE typeof(membership_revision) <> 'integer' OR membership_revision <= 0
                    OR typeof(projection_sequence) <> 'integer' OR projection_sequence <= 0
                    OR (room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence <= 0))
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_member_effects AS live
                JOIN \(shadowRooms) AS room ON room.room_id = live.room_id AND room.is_group_event_authorized = 1
                JOIN \(shadowMemberEffects) AS incoming ON incoming.source_event_id = live.source_event_id
                    OR (incoming.room_id = live.room_id AND incoming.user_id = live.user_id AND incoming.membership_revision = live.membership_revision)
                WHERE incoming.source_event_id <> live.source_event_id OR incoming.canonical_digest <> live.canonical_digest
                    OR (incoming.room_sequence IS NOT NULL AND live.room_sequence IS NOT NULL AND incoming.room_sequence <> live.room_sequence)
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try copyRoomRows(table: "v2_member_effects", shadow: shadowMemberEffects)
        try db.execute(sql: """
            UPDATE \(shadowMemberEffects) SET room_sequence = (
                SELECT live.room_sequence FROM v2_member_effects AS live WHERE live.source_event_id = \(shadowMemberEffects).source_event_id
            ) WHERE room_sequence IS NULL
            """)
        // The merged source history, including removals and re-additions, is
        // authoritative for each member; copying role rows alone resurrects roles.
        try db.execute(sql: "DELETE FROM \(shadowMemberRoles)")
        try db.execute(sql: """
            INSERT INTO \(shadowMemberRoles) (room_id, user_id, role, membership_revision, room_sequence)
            SELECT effect.room_id, effect.user_id, effect.role, effect.membership_revision,
                   COALESCE(effect.room_sequence, effect.projection_sequence)
            FROM \(shadowMemberEffects) AS effect
            WHERE effect.action = 'role' AND NOT EXISTS (
                SELECT 1 FROM \(shadowMemberEffects) AS newer
                WHERE newer.room_id = effect.room_id AND newer.user_id = effect.user_id
                  AND newer.membership_revision > effect.membership_revision
            )
            """)
        try copyRoomRows(table: "v2_group_permission_revisions", shadow: shadowPermissionRevisions)

        let shadowEvents = snapshotShadowTable(for: "v2_group_events")
        let shadowCursors = snapshotShadowTable(for: "v2_group_event_cursors")
        if try Bool.fetchOne(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL))
            SELECT EXISTS (
                SELECT 1 FROM v2_group_events AS event JOIN authorized AS room ON room.room_id = event.room_id
                WHERE typeof(event.room_sequence) <> 'integer' OR event.room_sequence <= 0
                UNION ALL
                SELECT 1 FROM v2_group_event_cursors AS cursor JOIN authorized AS room ON room.room_id = cursor.room_id
                WHERE typeof(cursor.applied_room_sequence) <> 'integer' OR cursor.applied_room_sequence < 0
                   OR typeof(cursor.log_trimmed_through_room_sequence) <> 'integer' OR cursor.log_trimmed_through_room_sequence < 0
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            WITH room_log_rooms AS (
                SELECT room_id
                FROM \(shadowRooms)
                WHERE is_group_event_authorized = 1
                UNION
                SELECT direct.room_id
                FROM (
                    SELECT room_id FROM \(shadowDirectProfiles)
                    UNION
                    SELECT room_id FROM \(shadowDirectIdentities)
                ) AS direct
                LEFT JOIN v2_room_event_authorizations AS authorization
                  ON authorization.room_id = direct.room_id
                WHERE COALESCE(authorization.is_authorized, 1) = 1
            )
            INSERT INTO \(shadowEvents)
            SELECT event.*
            FROM v2_group_events AS event
            JOIN room_log_rooms AS room ON room.room_id = event.room_id
            """)
        try db.execute(sql: """
            WITH room_log_rooms AS (
                SELECT room_id
                FROM \(shadowRooms)
                WHERE is_group_event_authorized = 1
                UNION
                SELECT direct.room_id
                FROM (
                    SELECT room_id FROM \(shadowDirectProfiles)
                    UNION
                    SELECT room_id FROM \(shadowDirectIdentities)
                ) AS direct
                LEFT JOIN v2_room_event_authorizations AS authorization
                  ON authorization.room_id = direct.room_id
                WHERE COALESCE(authorization.is_authorized, 1) = 1
            )
            INSERT INTO \(shadowCursors)
            SELECT cursor.*
            FROM v2_group_event_cursors AS cursor
            JOIN room_log_rooms AS room ON room.room_id = cursor.room_id
            """)
    }

    private static func preserveMessageEffectsInSnapshot(db: Database) throws {
        // Keep only receipts represented by the new authoritative baseline.
        // Future effects must replay if this reset installs an older revision;
        // removed rooms must not retain claims that suppress a later rebuild.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT message_revision FROM \(snapshotShadowTable(for: "v2_message_effects"))
                    UNION ALL SELECT effect.message_revision FROM v2_message_effects AS effect
                    JOIN \(snapshotShadowTable(for: "v2_message_projections")) AS message
                      ON message.message_id = effect.entity_key AND message.room_id = effect.room_id
                ) WHERE typeof(message_revision) <> 'integer' OR message_revision <= 0
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(snapshotShadowTable(for: "v2_message_effects"))
            SELECT effect.* FROM v2_message_effects AS effect
            JOIN \(snapshotShadowTable(for: "v2_message_projections")) AS message ON message.message_id = effect.entity_key
              AND message.room_id = effect.room_id
              AND message.message_revision >= effect.message_revision
            ON CONFLICT DO NOTHING
            """)
    }

    private static func snapshotShadowTable(for table: String) -> String {
        "v2_snapshot_shadow_" + table.dropFirst("v2_".count)
    }

    private static func snapshotRetiredTable(for table: String) -> String {
        "v2_snapshot_retired_" + table.dropFirst("v2_".count)
    }

    private static func createSnapshotShadowTable(for table: String, db: Database) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ), let createSQL: String = row["sql"] else {
            throw V2ClientSyncError.snapshotProjectionConflict
        }
        let plainPrefix = "CREATE TABLE \(table)"
        let quotedPrefix = "CREATE TABLE \"\(table)\""
        let prefix: String
        if createSQL.hasPrefix(plainPrefix) {
            prefix = plainPrefix
        } else if createSQL.hasPrefix(quotedPrefix) {
            prefix = quotedPrefix
        } else {
            throw V2ClientSyncError.snapshotProjectionConflict
        }
        let shadowSQL = "CREATE TABLE \(snapshotShadowTable(for: table))" + createSQL.dropFirst(prefix.count)
        try db.execute(sql: shadowSQL)
    }

    private static func validateSnapshotMembershipFences(table: String, db: Database) throws {
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM \(table)
                WHERE typeof(membership_revision) <> 'integer' OR membership_revision <= 0)
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
    }

    private static func createSnapshotShadowTables(db: Database) throws {
        try validateSnapshotMembershipFences(table: "v2_room_membership_states", db: db)
        for table in snapshotOrdinaryBankTables {
            try createSnapshotShadowTable(for: table, db: db)
        }
        try db.execute(sql: "INSERT INTO \(snapshotShadowTable(for: "v2_room_membership_states")) SELECT * FROM v2_room_membership_states")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(snapshotShadowTable(for: "v2_contact_profile_search")) USING fts5(
                display_unigrams,
                display_bigrams,
                handle_unigrams,
                handle_bigrams,
                tokenize = 'ascii',
                detail = full,
                columnsize = 0
            )
            """)
    }

    private static func dropSnapshotShadowTables(db: Database) throws {
        for table in snapshotVirtualBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotShadowTable(for: table))")
        }
        for table in snapshotOrdinaryBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotShadowTable(for: table))")
        }
    }

    private static func dropRetiredSnapshotTables(db: Database) throws {
        for table in snapshotVirtualBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotRetiredTable(for: table))")
        }
        for table in snapshotOrdinaryBankTables.reversed() {
            try db.execute(sql: "DROP TABLE IF EXISTS \(snapshotRetiredTable(for: table))")
        }
    }

    private static func snapshotShadowTablesExist(db: Database) throws -> Bool {
        for table in snapshotOrdinaryBankTables + snapshotVirtualBankTables {
            guard try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [snapshotShadowTable(for: table)]
            ) != nil else { return false }
        }
        return true
    }

    private static func prepareProfileSecurityFloorShadow(db: Database) throws {
        let floor = snapshotShadowTable(for: "v2_profile_invalidations")
        // Security floors outlive an individual cache and snapshot bank. Do
        // this data-proportional merge before ACK, never during the bank swap.
        try db.execute(sql: """
            INSERT INTO \(floor) SELECT * FROM v2_profile_invalidations WHERE true
            ON CONFLICT(user_id) DO UPDATE SET
                minimum_revision=excluded.minimum_revision, profile_state=excluded.profile_state, updated_at=excluded.updated_at
            WHERE excluded.minimum_revision > \(floor).minimum_revision
            """)
        for (table, userColumn, predicate) in [
            ("v2_direct_room_profile_projections", "target_user_id", "1"),
            ("v2_profile_views", "user_id", "state = 'active'")
        ] {
            try db.execute(sql: """
                DELETE FROM \(snapshotShadowTable(for: table)) AS profile WHERE \(predicate)
                AND EXISTS (SELECT 1 FROM \(floor) WHERE user_id = profile.\(userColumn) AND minimum_revision >= profile.revision)
                """)
        }
    }

    private static func prepareDeviceOwnedIdentityShadow(db: Database) throws {
        let identities = snapshotShadowTable(for: "v2_direct_room_identities")
        let invalidations = snapshotShadowTable(for: "v2_profile_invalidations")
        try db.execute(sql: """
            INSERT INTO \(identities)
            SELECT identity.*
            FROM v2_direct_room_identities AS identity
            WHERE NOT EXISTS (
                SELECT 1 FROM \(invalidations) AS invalidation
                WHERE invalidation.user_id = identity.target_user_id
                  AND NOT EXISTS (
                      SELECT 1 FROM \(snapshotShadowTable(for: "v2_profile_views")) AS profile
                      WHERE profile.user_id = identity.target_user_id AND profile.revision > invalidation.minimum_revision
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM v2_local_profile_display AS display
                      WHERE display.user_id = identity.target_user_id AND display.profile_revision > invalidation.minimum_revision
                  )
            )
            """)
    }

    private static func prepareContactSearchShadow(db: Database) throws {
        let search = snapshotShadowTable(for: "v2_contact_profile_search")
        let profiles = snapshotShadowTable(for: "v2_profile_views")
        try db.execute(sql: """
            INSERT INTO \(search)
                (rowid, display_unigrams, display_bigrams, handle_unigrams, handle_bigrams)
            SELECT rowid,
                   v2_contact_search_unigrams(display_name),
                   v2_contact_search_bigrams(display_name),
                   v2_contact_search_unigrams(public_handle),
                   v2_contact_search_bigrams(public_handle)
            FROM \(profiles)
            WHERE public_handle IS NOT NULL
            """)
    }

    private static func prepareMessageSearchControlShadow(db: Database) throws {
        let state = snapshotShadowTable(for: "v2_message_search_state")
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT index_version, generation FROM v2_message_search_state WHERE singleton = 1"
        ) else { throw V2ClientSyncError.snapshotProjectionConflict }
        let generation = try storageInteger(row, column: "generation")
        let indexVersion = try storageInteger(row, column: "index_version")
        guard generation > 0, indexVersion > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        guard generation < Int64.max else { throw V2ClientSyncError.storageRangeExceeded }
        try db.execute(
            sql: "INSERT INTO \(state) (singleton, index_version, state, generation) VALUES (1, ?, 'building', ?)",
            arguments: [indexVersion, generation + 1]
        )
    }

    private static func createSnapshotShadowIndexes(db: Database) throws {
        guard let snapshotID: String = try Row.fetchOne(
            db,
            sql: "SELECT snapshot_id FROM v2_snapshot_import LIMIT 1"
        )?["snapshot_id"] else { throw V2ClientSyncError.snapshotMismatch }
        let suffix = snapshotID.replacingOccurrences(of: "-", with: "")
        for table in snapshotOrdinaryBankTables {
            let shadow = snapshotShadowTable(for: table)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT name, sql FROM sqlite_master
                WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL
                ORDER BY name
                """,
                arguments: [table]
            )
            for (offset, row) in rows.enumerated() {
                let name: String = row["name"]
                let createSQL: String = row["sql"]
                let tableComponent = table.dropFirst("v2_".count)
                let shadowName = "v2_snapshot_\(suffix)_\(tableComponent)_\(offset)_idx"
                let indexToken = "INDEX \(name)"
                let plainTableToken = " ON \(table)"
                let quotedTableToken = " ON \"\(table)\""
                guard let indexRange = createSQL.range(of: indexToken, options: .caseInsensitive),
                      let tableRange = createSQL.range(of: plainTableToken, options: .caseInsensitive)
                        ?? createSQL.range(of: quotedTableToken, options: .caseInsensitive)
                else { throw V2ClientSyncError.snapshotProjectionConflict }
                var rewritten = createSQL.replacingCharacters(in: tableRange, with: " ON \(shadow)")
                guard let rewrittenIndexRange = rewritten.range(of: indexToken, options: .caseInsensitive) else {
                    throw V2ClientSyncError.snapshotProjectionConflict
                }
                rewritten.replaceSubrange(rewrittenIndexRange, with: "INDEX \(shadowName)")
                // Confirm the original range was meaningful before executing
                // dynamically reconstructed schema SQL.
                _ = indexRange
                try db.execute(sql: rewritten)
            }
        }
    }

    private static func suspendApplicationTriggers(db: Database) throws -> [(name: String, sql: String)] {
        let triggers: [(name: String, sql: String)] = try Row.fetchAll(
            db,
            sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND sql IS NOT NULL ORDER BY name"
        ).map { ($0["name"] as String, $0["sql"] as String) }
        for trigger in triggers {
            try db.execute(sql: "DROP TRIGGER \(trigger.name)")
        }
        return triggers
    }

    private static func restoreApplicationTriggers(
        _ triggers: [(name: String, sql: String)],
        db: Database
    ) throws {
        for trigger in triggers { try db.execute(sql: trigger.sql) }
    }

    static func requireProjectionWritesUnfenced(db: Database) throws {
        let prepared = try Bool.fetchOne(
            db,
            sql: "SELECT activation_prepared FROM v2_snapshot_import LIMIT 1"
        ) ?? false
        guard !prepared else { throw V2ClientSyncError.resetPending }
    }

    /// 快照分页写入的目标表路由。
    ///
    /// 显式路由让每个快照分页都走普通 DML，从而避免 schema 重写与 schema 锁失效，
    /// 使实时投影在可续传导入期间始终可读。
    enum ProjectionTableTarget {
        case live
        case snapshotShadow

        func table(_ liveName: String) -> String {
            switch self {
            case .live: liveName
            case .snapshotShadow: GRDBV2LocalSyncStore.snapshotShadowTable(for: liveName)
            }
        }
    }

    private static func applySnapshotItem(_ item: V2SnapshotProjectionItem, db: Database) throws {
        try requirePersonalProjection(item.key.projectionKind)
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: item.payload) as? [String: Any] else {
                throw V2ClientSyncError.snapshotProjectionConflict
            }
            object = value
        } catch {
            throw V2ClientSyncError.snapshotProjectionConflict
        }
        let payloadKey = try snapshotEntityKey(kind: item.key.projectionKind, sourceEventID: item.sourceEventID, object: object)
        guard payloadKey == item.key.entityKey else { throw V2ClientSyncError.snapshotProjectionConflict }
        let eventType = object["event_type"] as? String
        let recordKind = item.key.projectionKind == "room" && eventType == "membership_changed"
            ? "membership"
            : item.key.projectionKind
        let record = try V2ClientSyncRecord(
            sequence: item.sequence,
            sourceEventID: item.sourceEventID,
            projectionKind: recordKind,
            payload: item.payload
        )
        switch item.key.projectionKind {
        case "relationship": try applyRelationship(record, target: .snapshotShadow, db: db)
        case "user_block": try applyUserBlock(record, target: .snapshotShadow, db: db)
        case "stranger_message_permission": try applyStrangerMessagePermission(record, target: .snapshotShadow, db: db)
        case "user_add_permission": try applyUserAddPermission(record, target: .snapshotShadow, db: db)
        case "live_activity_preferences": try applyLiveActivityPreference(record,target:.snapshotShadow,db:db)
        case "direct_read_receipt": try applyDirectReadReceipt(record, target: .snapshotShadow, db: db)
        case "own_read_watermark": try applyOwnReadWatermark(record, target: .snapshotShadow, db: db)
        case "read_receipt_preferences": try applyReadReceiptPreference(record, target: .snapshotShadow, db: db)
        case "conversation_state": try persist(V2ClientConversationState(record: record), target: .snapshotShadow, db: db)
        case "message_favorite": try persist(V2ClientMessageFavorite(record: record), target: .snapshotShadow, db: db)
        case "contact_alias": try applyContactAliasInvalidation(record, target: .snapshotShadow, db: db)
        case "room": try applyMembershipAwareRoomProjection(record, target: .snapshotShadow, db: db)
        case "direct_room_profile": try persist(V2ClientDirectRoomProfileProjection(record: record), target: .snapshotShadow, db: db)
        case "timeline_activity": try persist(V2ClientTimelineActivityProjection(record: record), target: .snapshotShadow, db: db)
        case "direct_sending_capability": try persist(V2ClientDirectSendingCapability(record: record), target: .snapshotShadow, db: db)
        case "profile_invalidation": try persist(V2ClientProfileInvalidation(record: record), target: .snapshotShadow, db: db)
        default: throw V2ClientSyncError.snapshotProjectionConflict
        }
    }

    private static func snapshotEntityKey(
        kind: String,
        sourceEventID: EventID,
        object: [String: Any]
    ) throws -> String {
        func string(_ name: String) throws -> String {
            guard let value = object[name] as? String, !value.isEmpty else {
                throw V2ClientSyncError.snapshotProjectionConflict
            }
            return value
        }
        switch kind {
        case "room": return try string("room_id")
        // The personal projection worker canonicalizes this entity key to
        // lowercase UUID text, independently of the original payload spelling.
        case "own_read_watermark": return try string("room_id").lowercased()
        case "relationship", "user_block", "contact_alias": return try string("target_user_id")
        case "stranger_message_permission", "user_add_permission", "read_receipt_preferences", "live_activity_preferences": return "singleton"
        case "direct_room_profile", "direct_read_receipt", "conversation_state", "direct_sending_capability":
            return try string("room_id")
        case "message_favorite": return try string("message_id")
        case "timeline_activity": return sourceEventID.rawValue
        case "profile_invalidation": return try string("user_id")
        default: throw V2ClientSyncError.snapshotProjectionConflict
        }
    }

    private static func rebuildConversationListEntries(
        messages: String = "v2_message_projections",
        summaries: String = "v2_conversation_summaries",
        roomProfiles: String = "v2_room_profile_projections",
        directProfiles: String = "v2_direct_room_profile_projections",
        directIdentities: String = "v2_direct_room_identities",
        conversationStates: String = "v2_conversation_states",
        entries: String = "v2_conversation_list_entries",
        db: Database
    ) throws {
        let cachedRooms = entries == "v2_conversation_list_entries" ? "UNION SELECT room_id FROM v2_room_latest_visible" : ""
        let cachedActivity = entries == "v2_conversation_list_entries"
            ? "(SELECT created_at_reference + 978307200.0 FROM v2_room_latest_visible WHERE room_id = all_rooms.room_id)" : "NULL"
        try db.execute(sql: """
            DELETE FROM \(entries);
            WITH all_rooms AS (
                SELECT room_id FROM \(summaries)
                UNION SELECT room_id FROM \(roomProfiles)
                UNION SELECT room_id FROM \(directProfiles)
                UNION SELECT room_id FROM \(directIdentities)
                \(cachedRooms)
            )
            INSERT INTO \(entries)
                (room_id, last_activity, is_pinned, is_archived, mute_until)
            SELECT all_rooms.room_id,
                   COALESCE(
                       \(cachedActivity),
                       (SELECT message.server_created_at
                        FROM \(summaries) AS summary
                        JOIN \(messages) AS message
                          ON message.message_id = summary.message_id
                        WHERE summary.room_id = all_rooms.room_id),
                       (SELECT created_at FROM \(roomProfiles)
                        WHERE room_id = all_rooms.room_id),
                       (SELECT room_created_at FROM \(directProfiles)
                        WHERE room_id = all_rooms.room_id),
                       (SELECT room_created_at FROM \(directIdentities)
                        WHERE room_id = all_rooms.room_id), 0
                   ),
                   COALESCE(state.is_pinned, 0),
                   COALESCE(state.is_archived, 0),
                   COALESCE(state.mute_until, 0)
            FROM all_rooms
            LEFT JOIN \(conversationStates) AS state
              ON state.room_id = all_rooms.room_id
            """)
    }

    public func events() throws -> [V2ClientSyncRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT sequence, source_event_id, projection_kind, payload FROM v2_sync_events ORDER BY sequence").map(Self.decodeEvent)
        }
    }

    /// 读取指定房间的全部消息投影。
    ///
    /// 界面与仓储读取的是这份持久化投影，而不是在主线程上扫描不透明的同步事件字节。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 该房间的消息投影列表。
    /// - Throws: 数据库读取失败时抛出。
    public func messages(in roomID: RoomID) throws -> [V2ClientMessageProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_message_projections WHERE room_id = ? ORDER BY timeline_sequence, message_id", arguments: [roomID.rawValue]).map(Self.decodeMessageProjection)
        }
    }

    /// 由单次快照读取一页有界时间线（含装饰数据）。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Parameter cursor: 更早页面的游标；为空表示从最新开始。
    /// - Parameter limit: 本页最多返回的条目数。
    /// - Returns: 时间线分页。
    /// - Throws: 参数越界或数据库读取失败时抛出。
    public func conversationTimelinePage(
        in roomID: RoomID,
        before cursor: V2ClientTimelineCursor? = nil,
        limit: Int,
        presentationUserID: UserID? = nil
    ) throws -> V2ClientConversationTimelinePage {
        guard (1 ... 10_000).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try databasePool.read { db in
            let candidates = try Self.timelineCandidates(db: db, roomID: roomID, cursor: cursor, newer: false, limit: limit + 1)
            return try Self.timelinePage(db: db, roomID: roomID, selected: Array(candidates.prefix(limit).reversed()), hasOlder: candidates.count > limit, presentationUserID: presentationUserID)
        }
    }

    /// 读取包含目标消息的时间线窗口。
    ///
    /// 实现为一次消息标识查找加两次索引检索：开销与保留载荷都不随目标在房间历史中的深度增长，
    /// 不使用 OFFSET，也不扫描此前所有分页；账号、目标与装饰数据共享同一次读取快照。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - limit: 窗口内最多返回的条目数。
    /// - Returns: 目标消息所在的时间线窗口。
    /// - Throws: 参数越界或数据库读取失败时抛出。
    public func conversationTimelineWindow(
        in roomID: RoomID,
        for userID: UserID,
        around messageID: MessageID,
        before: Int,
        after: Int,
        aggregateReactions: Bool = false
    ) throws -> V2ClientTimelineLocation {
        guard (0..<800).contains(before), (0..<800).contains(after), before + after + 1 <= 800 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try databasePool.read { db in
            guard let storedUser = try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1"),
                  storedUser == userID.rawValue || (userID.uuidValue != nil && UUID(uuidString: storedUser) == userID.uuidValue),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ? AND room_id = ?", arguments: [messageID.rawValue, roomID.rawValue])
            else { return .unavailable }
            let revoked = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM v2_room_profile_projections WHERE room_id = ? AND is_group_event_authorized = 0
                    UNION ALL
                    SELECT 1 FROM v2_room_event_authorizations WHERE room_id = ? AND is_authorized = 0
                )
                """, arguments: [roomID.rawValue, roomID.rawValue]) ?? false
            guard !revoked else { return .unavailable }
            let target = try Self.decodeMessageProjection(row)
            guard !target.isWithdrawn else { return .withdrawn }
            let anchor = TimelinePageCandidate.message(target)
            let older = try Self.timelineCandidates(db: db, roomID: roomID, cursor: anchor.cursor, newer: false, limit: before + 1)
            let newer = try Self.timelineCandidates(db: db, roomID: roomID, cursor: anchor.cursor, newer: true, limit: after + 1)
            let selected = Array(older.prefix(before).reversed()) + [anchor] + Array(newer.prefix(after))
            let page = try Self.timelinePage(db: db, roomID: roomID, selected: selected, hasOlder: older.count > before, presentationUserID: aggregateReactions ? userID : nil)
            return .found(.init(page: page, newerBoundary: newer.count > after ? newer[after].cursor : nil))
        }
    }

    private static func timelineCandidates(db: Database, roomID: RoomID, cursor: V2ClientTimelineCursor?, newer: Bool, limit: Int) throws -> [TimelinePageCandidate] {
        let order = newer ? "ASC" : "DESC"
        func rows(table: String, id: String, kind: V2ClientTimelineItemKind, columns: String) throws -> [Row] {
            var predicate = ""
            var arguments: StatementArguments = [roomID.rawValue]
            if let cursor {
                // Kind is the final tie breaker when a message and a private
                // activity happen to share both their sequence and opaque ID.
                let inclusive = newer ? kind.rawValue > cursor.kind.rawValue : kind.rawValue < cursor.kind.rawValue
                let comparison = (newer ? ">" : "<") + (inclusive ? "=" : "")
                predicate = " AND (timeline_sequence, \(id)) \(comparison) (?, ?)"
                arguments += [try storageInteger(cursor.timelineSequence), cursor.itemID]
            }
            arguments += [limit]
            return try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) WHERE room_id = ?\(predicate) ORDER BY timeline_sequence \(order), \(id) \(order) LIMIT ?", arguments: arguments)
        }
        let messages = try rows(table: "v2_message_projections", id: "message_id", kind: .message, columns: "*").map(decodeMessageProjection).map(TimelinePageCandidate.message)
        let activities = try rows(table: "v2_timeline_activity_projections", id: "source_event_id", kind: .activity, columns: "source_event_id, room_id, timeline_sequence, event_type, server_created_at").map(decodeTimelineActivity).map(TimelinePageCandidate.activity)
        return Array((messages + activities).sorted(by: newer ? TimelinePageCandidate.olderFirst : TimelinePageCandidate.newerFirst).prefix(limit))
    }

    private static func timelinePage(db: Database, roomID: RoomID, selected: [TimelinePageCandidate], hasOlder: Bool, presentationUserID: UserID? = nil) throws -> V2ClientConversationTimelinePage {
        let messages = selected.compactMap(\.message)
        let activities = selected.compactMap(\.activity)
        let messageIDs = messages.map(\.messageID)

        let reactions: [V2ClientMessageReaction]
        let reactionSummaries: [V2ClientMessageReactionSummary]?
        let pinnedMessageIDs: Set<MessageID>
        let favoritedMessageIDs: Set<MessageID>
        if messageIDs.isEmpty {
            reactions = []
            reactionSummaries = presentationUserID == nil ? nil : []
            pinnedMessageIDs = []
            favoritedMessageIDs = []
        } else {
            let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
            let messageArguments = StatementArguments(messageIDs.map(\.rawValue))
            if let presentationUserID {
                reactions = []
                reactionSummaries = try Row.fetchAll(db, sql: """
                    SELECT message_id, reaction, COUNT(*) AS reaction_count,
                        MAX(actor_user_id = ?) AS includes_current_user
                    FROM v2_message_reactions
                    WHERE message_id IN (\(placeholders))
                    GROUP BY message_id, reaction ORDER BY message_id, reaction
                    """, arguments: StatementArguments([presentationUserID.rawValue]) + messageArguments).map { row in
                        .init(messageID: try .init(row["message_id"] as String), reaction: row["reaction"],
                              count: row["reaction_count"], includesCurrentUser: row["includes_current_user"])
                    }
            } else {
                reactionSummaries = nil
                reactions = try Row.fetchAll(
                    db,
                    sql: "SELECT room_id, message_id, actor_user_id, reaction FROM v2_message_reactions WHERE message_id IN (\(placeholders)) ORDER BY message_id, reaction, actor_user_id",
                    arguments: messageArguments
                ).map { row in
                    try .init(
                        roomID: .init(row["room_id"] as String),
                        messageID: .init(row["message_id"] as String),
                        actorUserID: .init(row["actor_user_id"] as String),
                        reaction: row["reaction"]
                    )
                }
            }
            pinnedMessageIDs = try Set(String.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_group_pinned_messages WHERE room_id = ? AND is_pinned = 1 AND message_id IN (\(placeholders))",
                arguments: StatementArguments([roomID.rawValue]) + messageArguments
            ).map(MessageID.init))
            favoritedMessageIDs = try Set(String.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_message_favorites WHERE is_favorited = 1 AND message_id IN (\(placeholders))",
                arguments: messageArguments
            ).map(MessageID.init))
        }

        let directReadReceipt: V2DirectReadReceiptProjection?
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT room_id, reader_user_id, read_through_room_sequence, recorded_at FROM v2_direct_read_receipt_projections WHERE room_id = ? AND is_visible = 1 AND read_through_room_sequence > 0",
            arguments: [roomID.rawValue]
        ) {
            directReadReceipt = try .init(
                roomID: .init(row["room_id"] as String),
                readerUserID: .init(row["reader_user_id"] as String),
                readThroughRoomSequence: Self.storageUnsigned(row, column: "read_through_room_sequence"),
                recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double),
                isVisible: true
            )
        } else {
            directReadReceipt = nil
        }

        let olderCursor = hasOlder ? selected.first.map(\.cursor) : nil
        return .init(
            messages: messages,
            activities: activities,
            reactions: reactions,
            pinnedMessageIDs: pinnedMessageIDs,
            favoritedMessageIDs: favoritedMessageIDs,
            directReadReceipt: directReadReceipt,
            olderCursor: olderCursor,
            reactionSummaries: reactionSummaries
        )
    }

    public func timelineActivities(in roomID: RoomID) throws -> [V2ClientTimelineActivityProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, timeline_sequence, event_type, server_created_at FROM v2_timeline_activity_projections WHERE room_id = ? ORDER BY timeline_sequence, source_event_id", arguments: [roomID.rawValue]).map(Self.decodeTimelineActivity)
        }
    }

    public func directSendingCapability(roomID: RoomID) throws -> V2ClientDirectSendingCapability? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT room_id, can_send, state_version, updated_at FROM v2_direct_sending_capabilities WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return .init(roomID: try .init(row["room_id"] as String), canSend: row["can_send"], stateVersion: try Self.storageUnsigned(row, column: "state_version"), updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
        }
    }

    public func conversationState(roomID: RoomID) throws -> V2ClientConversationState? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT room_id, is_pinned, is_archived, mute_until, updated_at, revision FROM v2_conversation_states WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeConversationState(row)
        }
    }

    /// 批量读取全部会话状态，供测试与诊断使用。
    ///
    /// 生产环境的列表渲染使用下方有界的物化会话分页。
    ///
    /// - Returns: 按房间标识索引的会话状态。
    /// - Throws: 数据库读取失败时抛出。
    func conversationStates() throws -> [RoomID: V2ClientConversationState] {
        try databasePool.read { db in
            let states = try Row.fetchAll(
                db,
                sql: "SELECT room_id, is_pinned, is_archived, mute_until, updated_at, revision FROM v2_conversation_states"
            ).map(Self.decodeConversationState)
            return Dictionary(uniqueKeysWithValues: states.map { ($0.roomID, $0) })
        }
    }

    public func isMessageFavorited(_ messageID: MessageID) throws -> Bool {
        try databasePool.read { db in (try Bool.fetchOne(db, sql: "SELECT is_favorited FROM v2_message_favorites WHERE message_id = ?", arguments: [messageID.rawValue])) ?? false }
    }

    /// 以一次查询读取房间内被收藏的消息标识，用于时间线装饰。
    ///
    /// 这样无需为每条可见消息各查一次。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 被收藏的消息标识集合。
    /// - Throws: 数据库读取失败时抛出。
    public func favoritedMessageIDs(in roomID: RoomID) throws -> Set<MessageID> {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_message_favorites WHERE room_id = ? AND is_favorited = 1",
                arguments: [roomID.rawValue]
            )
            return try Set(rows.map { try MessageID($0["message_id"] as String) })
        }
    }

    /// 面向已授权本地消息的个人收藏视图。
    ///
    /// 收藏是投影而不是第二份消息缓存，因此撤回与重置行为与普通时间线完全一致。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - limit: 本页最多返回的条数。
    ///   - cursor: 上一页游标。
    /// - Returns: 收藏消息分页。
    /// - Throws: 参数越界或数据库读取失败时抛出。
    public func favoritedMessages(
        before cursor: V2ClientFavoriteMessageCursor? = nil,
        limit: Int = 50
    ) throws -> V2ClientFavoriteMessagePage {
        guard (1 ... 100).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try databasePool.read { db -> V2ClientFavoriteMessagePage in
            let predicate: String
            var arguments: StatementArguments
            if let cursor {
                predicate = "AND (favorite.updated_at < ? OR (favorite.updated_at = ? AND message.message_id < ?))"
                arguments = [cursor.updatedAt.timeIntervalSince1970, cursor.updatedAt.timeIntervalSince1970, cursor.messageID.rawValue, limit + 1]
            } else {
                predicate = ""
                arguments = [limit + 1]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT message.*
                     , favorite.updated_at AS favorite_updated_at
                FROM v2_message_favorites AS favorite
                INNER JOIN v2_message_projections AS message
                    ON message.message_id = favorite.message_id
                WHERE favorite.is_favorited = 1 AND message.is_withdrawn = 0
                \(predicate)
                ORDER BY favorite.updated_at DESC, message.message_id DESC
                LIMIT ?
                """,
                arguments: arguments
            )
            let pageRows = rows.prefix(limit)
            let messages = try pageRows.map(Self.decodeMessageProjection)
            let nextCursor: V2ClientFavoriteMessageCursor? = rows.count > limit ? try pageRows.last.map { row in
                V2ClientFavoriteMessageCursor(
                    updatedAt: Date(timeIntervalSince1970: row["favorite_updated_at"] as Double),
                    messageID: try .init(row["message_id"] as String)
                )
            } : nil
            return V2ClientFavoriteMessagePage(messages: messages, nextCursor: nextCursor)
        }
    }

    /// 仅为有界的单个界面分页解析标题。
    ///
    /// 群房间优先使用群投影；私聊房间优先使用已同步的私聊资料，而不是更早的发现缓存。
    ///
    /// - Parameter roomIDs: 本页涉及的房间列表。
    /// - Returns: 房间到标题的映射。
    /// - Throws: 数据库读取失败时抛出。
    public func conversationTitles(for roomIDs: [RoomID]) throws -> [RoomID: String] {
        guard roomIDs.count <= 100 else { throw V2ClientProjectionError.invalidMessagePayload }
        let unique = Array(Set(roomIDs)).sorted()
        guard !unique.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let arguments = StatementArguments(unique.map(\.rawValue))
        return try databasePool.read { db in
            var titles: [RoomID: String] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT room_id, display_name FROM v2_direct_room_identities WHERE room_id IN (\(placeholders))",
                arguments: arguments
            ) {
                titles[try .init(row["room_id"] as String)] = row["display_name"]
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT room_id, display_name FROM v2_direct_room_profile_projections WHERE room_id IN (\(placeholders))",
                arguments: arguments
            ) {
                titles[try .init(row["room_id"] as String)] = row["display_name"]
            }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT room_id, title FROM v2_room_profile_projections WHERE room_id IN (\(placeholders))",
                arguments: arguments
            ) {
                titles[try .init(row["room_id"] as String)] = row["title"]
            }
            return titles
        }
    }

    /// Reads at most one page in a single SQLite snapshot. Direct profile text
    /// is deliberately excluded: these facts select a lookup, not display access.
    public func conversationLookupContexts(for roomIDs: [RoomID]) throws -> [RoomID: V2ClientConversationLookupContext] {
        guard roomIDs.count <= 100 else { throw V2ClientProjectionError.invalidMessagePayload }
        let unique = Array(Set(roomIDs)).sorted()
        guard !unique.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let arguments = StatementArguments(unique.map(\.rawValue))
        return try databasePool.read { db in
            var contexts: [RoomID: V2ClientConversationLookupContext] = [:]
            for table in ["v2_direct_room_identities", "v2_direct_room_profile_projections"] {
                for row in try Row.fetchAll(db,
                    sql: "SELECT room_id, target_user_id FROM \(table) WHERE room_id IN (\(placeholders))", arguments: arguments) {
                    contexts[try .init(row["room_id"] as String)] = .direct(peerUserID: try .init(row["target_user_id"] as String))
                }
            }
            for row in try Row.fetchAll(db,
                sql: "SELECT room_id, title FROM v2_room_profile_projections WHERE room_id IN (\(placeholders))", arguments: arguments) {
                contexts[try .init(row["room_id"] as String)] = .group(title: row["title"])
            }
            return contexts
        }
    }

    /// 读取房间最新的群公告。
    ///
    /// 它是物化的同步投影，而不是「碰巧创建了该公告的命令」留下的缓存响应。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 公告投影；不存在时返回 `nil`。
    /// - Throws: 数据库读取失败时抛出。
    public func groupAnnouncement(roomID: RoomID) throws -> V2ClientGroupAnnouncement? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT room_id, body, revision, updated_at FROM v2_group_announcements WHERE room_id = ?",
                arguments: [roomID.rawValue]
            ) else { return nil }
            return try .init(
                roomID: .init(row["room_id"] as String),
                body: row["body"],
                revision: try Self.storageUnsigned(row, column: "revision"),
                updatedAt: .init(timeIntervalSince1970: row["updated_at"] as Double)
            )
        }
    }

    /// A lower bound used to invalidate ephemeral presentation leases after sync or restart.
    public func groupAvatarRevision(roomID: RoomID) throws -> UInt64 {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT revision FROM v2_group_avatar_invalidations WHERE room_id=?", arguments: [roomID.rawValue]) else { return 0 }
            return UInt64(try Self.effectInteger(row, "revision"))
        }
    }

    public func pinnedMessageIDs(roomID: RoomID) throws -> Set<MessageID> {
        try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT message_id FROM v2_group_pinned_messages WHERE room_id = ? AND is_pinned = 1",
                arguments: [roomID.rawValue]
            )
            return try Set(rows.map { try MessageID($0["message_id"] as String) })
        }
    }

    /// 记录一次可重试的基线读取意图，但不修改消息、游标或发件箱。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 本次恢复请求。
    /// - Throws: 数据库写入失败时抛出。
    public func requestRolePolicyBaseline(roomID: RoomID) throws -> V2RolePolicyRecoveryRequest {
        try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            return try Self.enqueueRolePolicyRecovery(roomID: roomID, db: db)
        }
    }

    /// 供恢复运行器使用的有界发现。
    ///
    /// 已排队且仍然有效的请求会被排除，使后续分页能够覆盖其他房间。
    ///
    /// - Parameter limit: 本次最多补建的房间数。
    /// - Returns: 本次补建的请求数量。
    /// - Throws: 数据库读写失败时抛出。
    public func enqueueMissingRolePolicyBaselines(limit: Int = 32) throws -> Int {
        guard (1 ... 100).contains(limit) else { throw V2RolePolicyRecoveryError.invalidLimit }
        return try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            guard try Self.boundRolePolicyRecoveryAccount(db: db) != nil else { throw V2RolePolicyRecoveryError.accountUnavailable }
            try db.execute(sql: """
                DELETE FROM v2_role_policy_recovery_requests WHERE room_id IN (
                    SELECT request.room_id FROM v2_role_policy_recovery_requests AS request
                    LEFT JOIN v2_room_profile_projections AS room ON room.room_id = request.room_id AND room.is_group_event_authorized = 1
                    WHERE room.room_id IS NULL ORDER BY request.room_id LIMIT ?
                )
                """, arguments: [limit])
            let rooms = try String.fetchAll(db, sql: """
                SELECT room.room_id FROM v2_room_profile_projections AS room
                LEFT JOIN v2_group_role_policy_baselines AS baseline ON baseline.room_id = room.room_id
                LEFT JOIN v2_role_policy_recovery_requests AS request ON request.room_id = room.room_id
                JOIN v2_local_installation AS account ON account.singleton = 1
                WHERE room.is_group_event_authorized = 1
                  AND ((baseline.room_id IS NULL AND request.room_id IS NULL) OR request.membership_revision <> room.membership_revision
                       OR request.membership_source_event_id <> room.source_event_id
                       OR request.generation <> COALESCE((SELECT generation FROM v2_sync_cursor WHERE singleton = 1), 1)
                       OR request.installation_binding <> account.binding OR request.user_id <> account.user_id)
                ORDER BY room.room_id LIMIT ?
                """, arguments: [limit])
            for room in rooms { _ = try Self.enqueueRolePolicyRecovery(roomID: .init(room), db: db) }
            return rooms.count
        }
    }

    public func pendingRolePolicyBaselineRequests(limit: Int = 32) throws -> [V2RolePolicyRecoveryRequest] {
        guard (1 ... 100).contains(limit) else { throw V2RolePolicyRecoveryError.invalidLimit }
        return try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v2_role_policy_recovery_requests ORDER BY room_id LIMIT ?", arguments: [limit]).map(Self.decodeRolePolicyRecoveryRequest)
        }
    }

    public func dueRolePolicyBaselineRequests(at date: Date, limit: Int = 32) throws -> [V2RolePolicyRecoveryRequest] {
        guard (1 ... 100).contains(limit), date.timeIntervalSince1970.isFinite else { throw V2RolePolicyRecoveryError.invalidLimit }
        return try databasePool.read { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            return try Row.fetchAll(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE state = 'pending' AND next_attempt_at <= ? ORDER BY next_attempt_at, room_id LIMIT ?", arguments: [date.timeIntervalSince1970, limit]).map(Self.decodeRolePolicyRecoveryRequest)
        }
    }

    public func resumeRolePolicyBaseline(roomID: RoomID) throws -> V2RolePolicyRecoveryRequest {
        try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue])
            return try Self.enqueueRolePolicyRecovery(roomID: roomID, db: db)
        }
    }

    @discardableResult
    public func recordRolePolicyRecoveryFailure(_ disposition: V2RolePolicyRecoveryDisposition, for request: V2RolePolicyRecoveryRequest) throws -> Bool {
        try Task.checkCancellation()
        return try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            guard try Self.matchesRolePolicyRecoveryRequest(request, db: db) else { return false }
            switch disposition {
            case .unauthorized:
                try db.execute(sql: "UPDATE v2_room_profile_projections SET is_group_event_authorized = 0 WHERE room_id = ?", arguments: [request.roomID.rawValue])
                try db.execute(sql: "DELETE FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [request.roomID.rawValue])
                try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [request.roomID.rawValue])
            case .pause:
                try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET state = 'paused', attempt_count = MIN(attempt_count + 1, 2147483647) WHERE room_id = ?", arguments: [request.roomID.rawValue])
            case .retry(let date):
                guard date.timeIntervalSince1970.isFinite else { throw V2RolePolicyRecoveryError.invalidBaseline }
                try db.execute(sql: "UPDATE v2_role_policy_recovery_requests SET next_attempt_at = ?, attempt_count = MIN(attempt_count + 1, 2147483647) WHERE room_id = ?", arguments: [date.timeIntervalSince1970, request.roomID.rawValue])
            }
            return true
        }
    }

    /// 保存基线读取结果。
    ///
    /// 返回 `false` 表示该请求已被取代或其本地栅栏已变化；此时不会改变任何状态，
    /// 恢复运行器可以重新发现一个新的请求。
    ///
    /// - Parameter baseline: 服务端返回的策略基线。
    /// - Parameter expected: 期望的当前请求。
    /// - Returns: 保存生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    @discardableResult
    public func completeRolePolicyBaseline(_ baseline: V2GroupRolePolicyBaseline, for request: V2RolePolicyRecoveryRequest) throws -> Bool {
        try Task.checkCancellation()
        return try databasePool.write { db in
            try Self.requireRolePolicyRecoveryReady(db: db)
            guard try Self.matchesRolePolicyRecoveryRequest(request, db: db) else { return false }
            guard baseline.roomID == request.roomID, baseline.membershipRevision >= UInt64(request.membershipRevision) else { throw V2RolePolicyRecoveryError.invalidBaseline }
            if let current = try Row.fetchOne(db, sql: "SELECT revision FROM v2_group_permission_revisions WHERE room_id = ?", arguments: [request.roomID.rawValue]) {
                _ = try Self.rolePolicyInteger(current, column: "revision")
            }
            // Check observed roles before a revision equality predicate could hide corruption.
            for observed in try Row.fetchAll(db, sql: "SELECT revision, room_sequence FROM v2_group_role_policies WHERE room_id = ?", arguments: [request.roomID.rawValue]) {
                _ = try Self.effectInteger(observed, "revision")
                _ = try Self.optionalEffectInteger(observed, "room_sequence")
            }
            let admin = try Self.encodeRolePolicyPermissions(baseline.adminPermissions)
            let member = try Self.encodeRolePolicyPermissions(baseline.memberPermissions)
            let revision = Int64(baseline.permissionRevision)
            let previous = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [request.roomID.rawValue])
            let previousRevision = try previous.map { try Self.rolePolicyInteger($0, column: "permission_revision") } ?? 0
            let previousMembership = try previous.map { try Self.rolePolicyInteger($0, column: "membership_revision") } ?? 0
            let previousSequence = try previous.map { try Self.rolePolicyInteger($0, column: "room_sequence", minimum: 0) } ?? 0
            if let previous, previousRevision == revision {
                guard (previous["admin_permissions"] as Data) == admin, (previous["member_permissions"] as Data) == member else { throw V2RolePolicyRecoveryError.invalidBaseline }
            }
            guard previousRevision <= revision else { return false }
            var replaceObservation = true
            if previous != nil, replaceObservation {
                let membership = Int64(baseline.membershipRevision)
                let sequence = Int64(baseline.roomSequence)
                if previousRevision == revision, membership <= previousMembership, sequence <= previousSequence {
                    replaceObservation = false
                } else {
                    guard membership >= previousMembership, sequence >= previousSequence else { throw V2RolePolicyRecoveryError.invalidBaseline }
                }
            }
            if replaceObservation {
                for (role, permissions) in [("admin", admin), ("member", member)] {
                    if let observed = try Data.fetchOne(db, sql: "SELECT permissions FROM v2_group_role_policies WHERE room_id = ? AND role = ? AND revision = ?", arguments: [request.roomID.rawValue, role, revision]), observed != permissions {
                        throw V2RolePolicyRecoveryError.invalidBaseline
                    }
                }
                try db.execute(sql: """
                    INSERT INTO v2_group_role_policy_baselines (room_id, permission_revision, membership_revision, room_sequence, admin_permissions, member_permissions)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(room_id) DO UPDATE SET permission_revision = excluded.permission_revision,
                        membership_revision = excluded.membership_revision,
                        room_sequence = excluded.room_sequence,
                        admin_permissions = excluded.admin_permissions, member_permissions = excluded.member_permissions
                    """, arguments: [request.roomID.rawValue, revision, Int64(baseline.membershipRevision), Int64(baseline.roomSequence), admin, member])
            }
            try db.execute(sql: "INSERT INTO v2_group_permission_revisions (room_id, revision) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET revision = MAX(v2_group_permission_revisions.revision, excluded.revision)", arguments: [request.roomID.rawValue, revision])
            try db.execute(sql: "DELETE FROM v2_role_policy_recovery_requests WHERE room_id = ? AND request_id = ?", arguments: [request.roomID.rawValue, request.requestID.uuidString])
            return true
        }
    }

    private static func matchesRolePolicyRecoveryRequest(_ request: V2RolePolicyRecoveryRequest, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [request.roomID.rawValue]),
                  try Self.decodeRolePolicyRecoveryRequest(row) == request,
                  let account = try Self.boundRolePolicyRecoveryAccount(db: db),
                  account.binding == request.installationBinding, account.user == request.userID,
                  let room = try Row.fetchOne(db, sql: "SELECT * FROM v2_room_profile_projections WHERE room_id = ? AND is_group_event_authorized = 1", arguments: [request.roomID.rawValue]),
                  (try rolePolicyInteger(room, column: "membership_revision")) == request.membershipRevision,
                  (room["source_event_id"] as String) == request.membershipSourceEventID,
                  (try Self.readCursor(db)?.generation ?? 1) == UInt64(request.generation)
            else { return false }
        return true
    }

    private static func requireRolePolicyRecoveryReady(db: Database) throws {
        try requireProjectionWritesUnfenced(db: db)
        if let cursor = try readCursor(db), cursor.state != .ready { throw V2ClientSyncError.resetPending }
    }

    private static func boundRolePolicyRecoveryAccount(db: Database) throws -> (binding: String, user: UserID)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1"),
              let user: String = row["user_id"] else { return nil }
        return (row["binding"], try UserID(user))
    }

    private static func enqueueRolePolicyRecovery(roomID: RoomID, db: Database) throws -> V2RolePolicyRecoveryRequest {
        guard let account = try boundRolePolicyRecoveryAccount(db: db) else { throw V2RolePolicyRecoveryError.accountUnavailable }
        guard let room = try Row.fetchOne(db, sql: "SELECT membership_revision, source_event_id FROM v2_room_profile_projections WHERE room_id = ? AND is_group_event_authorized = 1", arguments: [roomID.rawValue]) else { throw V2RolePolicyRecoveryError.roomUnauthorized }
        let generation = try storageInteger(readCursor(db)?.generation ?? 1)
        let membership = try rolePolicyInteger(room, column: "membership_revision")
        let source: String = room["source_event_id"]
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue]) {
            let previous = try decodeRolePolicyRecoveryRequest(row)
            if previous.installationBinding == account.binding, previous.userID == account.user,
               previous.membershipRevision == membership, previous.membershipSourceEventID == source, previous.generation == generation { return previous }
        }
        let request = V2RolePolicyRecoveryRequest(roomID: roomID, requestID: UUID(), installationBinding: account.binding, userID: account.user, membershipRevision: membership, membershipSourceEventID: source, generation: generation, attemptCount: 0)
        try db.execute(sql: """
            INSERT INTO v2_role_policy_recovery_requests (room_id, request_id, installation_binding, user_id, membership_revision, membership_source_event_id, generation)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET request_id = excluded.request_id, installation_binding = excluded.installation_binding,
                user_id = excluded.user_id, membership_revision = excluded.membership_revision,
                membership_source_event_id = excluded.membership_source_event_id, generation = excluded.generation, attempt_count = 0, next_attempt_at = 0, state = 'pending'
            """, arguments: [roomID.rawValue, request.requestID.uuidString, account.binding, account.user.rawValue, membership, source, generation])
        return request
    }

    private static func rolePolicyInteger(_ row: Row, column: String, minimum: Int64 = 1) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage, integer >= minimum else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return integer
    }

    private static func decodeRolePolicyRecoveryRequest(_ row: Row) throws -> V2RolePolicyRecoveryRequest {
        let attemptValue: DatabaseValue = row["attempt_count"]
        let membershipValue: DatabaseValue = row["membership_revision"]
        let generationValue: DatabaseValue = row["generation"]
        guard case .int64(let attemptCount) = attemptValue.storage,
              case .int64(let membershipRevision) = membershipValue.storage,
              case .int64(let generation) = generationValue.storage,
              membershipRevision > 0, generation > 0,
              (0...Int64(Int32.max)).contains(attemptCount),
              let id = UUID(uuidString: row["request_id"] as String) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try .init(roomID: .init(row["room_id"] as String), requestID: id, installationBinding: row["installation_binding"], userID: .init(row["user_id"] as String), membershipRevision: membershipRevision, membershipSourceEventID: row["membership_source_event_id"], generation: generation, attemptCount: Int(attemptCount))
    }

    private static func encodeRolePolicyPermissions(_ permissions: Set<V2GroupPermission>) throws -> Data {
        try JSONEncoder().encode(permissions.map(\.rawValue).sorted())
    }

    /// 读取房间的角色策略。
    ///
    /// 缺失角色在事件或一次完整的归属观测确立其取值之前保持未知状态；
    /// 基线不会凭空造出事件。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 已知的角色策略列表。
    /// - Throws: 数据库读取失败时抛出。
    public func groupRolePolicies(roomID: RoomID) throws -> [V2ClientGroupRolePolicy] {
        try databasePool.read { try Self.readGroupRolePolicies(roomID: roomID, db: $0) }
    }

    public func groupRolePolicyState(roomID: RoomID) throws -> V2ClientGroupRolePolicyState {
        try databasePool.read { db in
            guard try Self.boundRolePolicyRecoveryAccount(db: db) != nil,
                  try Bool.fetchOne(db, sql: "SELECT is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) == true
            else { return .init(policies: [], recovery: .unavailable) }
            let policies = try Self.readGroupRolePolicies(roomID: roomID, db: db)
            if let cursor = try Self.readCursor(db), cursor.state != .ready {
                return .init(policies: policies, recovery: .waitingForSynchronization)
            }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_role_policy_recovery_requests WHERE room_id = ?", arguments: [roomID.rawValue]) {
                let request = try Self.decodeRolePolicyRecoveryRequest(row)
                guard try Self.matchesRolePolicyRecoveryRequest(request, db: db) else { return .init(policies: policies, recovery: .needed) }
                switch row["state"] as String {
                case "paused": return .init(policies: policies, recovery: .paused)
                case "pending": return .init(policies: policies, recovery: .pending(nextAttemptAt: .init(timeIntervalSince1970: row["next_attempt_at"] as Double)))
                default: throw V2ClientProjectionError.invalidMessagePayload
                }
            }
            let hasBaseline = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_group_role_policy_baselines WHERE room_id = ?)", arguments: [roomID.rawValue]) == true
            return .init(policies: policies, recovery: hasBaseline ? .ready : .needed)
        }
    }

    private static func readGroupRolePolicies(roomID: RoomID, db: Database) throws -> [V2ClientGroupRolePolicy] {
        if try Bool.fetchOne(db, sql: "SELECT is_group_event_authorized FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) == false { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM v2_group_role_policies WHERE room_id = ? ORDER BY role", arguments: [roomID.rawValue])
        let baseline = try Row.fetchOne(db, sql: "SELECT * FROM v2_group_role_policy_baselines WHERE room_id = ?", arguments: [roomID.rawValue])
        if let baseline {
            _ = try rolePolicyInteger(baseline, column: "membership_revision")
            _ = try rolePolicyInteger(baseline, column: "room_sequence", minimum: 0)
        }
        let storedBaselineRevision = try baseline.map { try rolePolicyInteger($0, column: "permission_revision") }
        let revisionRow = try Row.fetchOne(db, sql: "SELECT revision FROM v2_group_permission_revisions WHERE room_id = ?", arguments: [roomID.rawValue])
        let storedRevision = try revisionRow.map { try rolePolicyInteger($0, column: "revision") }
        for row in rows { _ = try rolePolicyInteger(row, column: "revision") }
        let baselineRevision = storedBaselineRevision ?? 0
        let revision = try Self.storageUnsigned(max(storedRevision ?? 1, baselineRevision))
        var observed = Dictionary(uniqueKeysWithValues: rows.map { ($0["role"] as String, $0) })
        var result: [V2ClientGroupRolePolicy] = []
        for role in [V2RoomMembershipRole.admin, .member] {
            let row = observed.removeValue(forKey: role.rawValue)
            let data: Data
            if let baseline, (try row.map { try rolePolicyInteger($0, column: "revision") } ?? 0) <= baselineRevision {
                data = baseline[role == .admin ? "admin_permissions" : "member_permissions"]
            } else if let row { data = row["permissions"] }
            else { continue }
            let names = try JSONDecoder().decode([String].self, from: data)
            let permissions = Set(names.compactMap(V2GroupPermission.init(rawValue:)))
            guard permissions.count == names.count else { throw V2ClientProjectionError.invalidMessagePayload }
            result.append(.init(roomID: roomID, role: role, permissions: permissions, revision: revision))
        }
        guard observed.isEmpty else { throw V2ClientProjectionError.invalidMessagePayload }
        return result
    }

    /// 在有界事务中重建派生字符索引。
    ///
    /// 重建期间持久化消息投影保持可读；调用方应对外暴露 `.building` 状态，
    /// 而不是把部分索引当作空搜索结果。

    /// 通过物化排序索引读取一页收件箱或归档列表。
    ///
    /// 键集谓词与索引顺序完全一致，且本页全部细节都在同一读事务内补齐。
    ///
    /// - Parameters:
    ///   - isArchived: 是否读取归档列表。
    ///   - cursor: 上一页游标。
    ///   - limit: 本页最多返回的条数。
    /// - Returns: 会话列表分页。
    /// - Throws: 参数越界或数据库读取失败时抛出。
    public func conversationListPage(
        isArchived: Bool,
        before cursor: V2ClientConversationListCursor? = nil,
        limit: Int = 50
    ) throws -> V2ClientConversationListPage {
        guard (1 ... 100).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        return try databasePool.read { db in
            let predicate: String
            let arguments: StatementArguments
            if let cursor {
                predicate = """
                    AND (
                        is_pinned < ?
                        OR (is_pinned = ? AND last_activity < ?)
                        OR (is_pinned = ? AND last_activity = ? AND room_id > ?)
                    )
                    """
                arguments = [
                    isArchived,
                    cursor.isPinned,
                    cursor.isPinned,
                    cursor.lastActivity.timeIntervalSince1970,
                    cursor.isPinned,
                    cursor.lastActivity.timeIntervalSince1970,
                    cursor.roomID.rawValue,
                    limit + 1,
                ]
            } else {
                predicate = ""
                arguments = [isArchived, limit + 1]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT room_id, last_activity, is_pinned, is_archived, mute_until
                FROM v2_conversation_list_entries
                WHERE is_archived = ?
                \(predicate)
                ORDER BY is_pinned DESC, last_activity DESC, room_id ASC
                LIMIT ?
                """,
                arguments: arguments
            )
            let pageRows = Array(rows.prefix(limit))
            guard !pageRows.isEmpty else { return .init(entries: [], nextCursor: nil) }

            let entries = try Self.conversationListEntries(pageRows, db: db)
            let nextCursor: V2ClientConversationListCursor? = rows.count > limit ? try pageRows.last.map { row in
                try .init(
                    isPinned: row["is_pinned"],
                    lastActivity: Date(timeIntervalSince1970: row["last_activity"] as Double),
                    roomID: .init(row["room_id"] as String)
                )
            } : nil
            return .init(entries: entries, nextCursor: nextCursor)
        }
    }

    public func reactions(for messageID: MessageID) throws -> [V2ClientMessageReaction] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_id, message_id, actor_user_id, reaction FROM v2_message_reactions WHERE message_id = ? ORDER BY reaction, actor_user_id", arguments: [messageID.rawValue]).map { row in
                try .init(roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), actorUserID: .init(row["actor_user_id"] as String), reaction: row["reaction"])
            }
        }
    }

    /// 以一次查询读取某个可见会话所需的全部表情记录。
    ///
    /// 调用方可以据此自行分组这些值投影，而不必为每条渲染消息各执行一次查询（避免 N+1 读取）。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 该房间的表情记录。
    /// - Throws: 数据库读取失败时抛出。
    public func reactions(in roomID: RoomID) throws -> [V2ClientMessageReaction] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT room_id, message_id, actor_user_id, reaction FROM v2_message_reactions WHERE room_id = ? ORDER BY message_id, reaction, actor_user_id", arguments: [roomID.rawValue]).map { row in
                try .init(roomID: .init(row["room_id"] as String), messageID: .init(row["message_id"] as String), actorUserID: .init(row["actor_user_id"] as String), reaction: row["reaction"])
            }
        }
    }

    /// 批量读取全部关系，供测试与诊断使用。
    ///
    /// 生产环境联系人使用有界分页接口，避免刷新时把庞大关系图整体物化。
    ///
    /// - Returns: 关系投影列表。
    /// - Throws: 数据库读取失败时抛出。
    func relationships() throws -> [V2ClientRelationshipProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT target_user_id, state, requested_by_user_id, updated_at FROM v2_relationship_projections ORDER BY target_user_id").map(Self.decodeRelationshipProjection)
        }
    }

    public func relationshipPage(
        scope: V2ClientRelationshipPageScope,
        matching query: String? = nil,
        before cursor: V2ClientRelationshipCursor? = nil,
        limit: Int = 50,
        includeTotalCount: Bool = false
    ) throws -> V2ClientRelationshipPage {
        guard (1 ... 100).contains(limit) else { throw V2ClientProjectionError.invalidMessagePayload }
        let selection = try Self.relationshipListSelection(scope: scope, matching: query)
        var clauses = selection.clauses
        var arguments = selection.arguments
        let countClauses = includeTotalCount ? clauses : []
        let countArguments = includeTotalCount ? arguments : []
        if let cursor {
            clauses.append("(relationship.updated_at < ? OR (relationship.updated_at = ? AND relationship.target_user_id > ?))")
            arguments += [cursor.updatedAt.timeIntervalSince1970, cursor.updatedAt.timeIntervalSince1970, cursor.targetUserID.rawValue]
        }
        let whereClause = clauses.joined(separator: " AND ")
        let searchJoin = selection.searchJoin
        return try databasePool.read { db in
            var pageArguments = arguments
            pageArguments += [limit + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT relationship.target_user_id, relationship.state,
                       relationship.requested_by_user_id, relationship.updated_at
                FROM v2_relationship_projections AS relationship
                \(searchJoin)
                WHERE \(whereClause)
                ORDER BY relationship.updated_at DESC, relationship.target_user_id ASC
                LIMIT ?
                """,
                arguments: pageArguments
            )
            let pageRows = Array(rows.prefix(limit))
            let relationships = try pageRows.map(Self.decodeRelationshipProjection)
            let nextCursor: V2ClientRelationshipCursor? = rows.count > limit ? try pageRows.last.map { row in
                try .init(
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
                    targetUserID: .init(row["target_user_id"] as String)
                )
            } : nil

            // Exact counts are opt-in because an index COUNT is still linear
            // work. The contacts UI requests it only for the first incoming-
            // request page that owns the badge.
            let totalCount: Int? = if includeTotalCount {
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*)
                    FROM v2_relationship_projections AS relationship
                    \(searchJoin)
                    WHERE \(countClauses.joined(separator: " AND "))
                    """,
                    arguments: countArguments
                ) ?? 0
            } else {
                nil
            }
            return .init(relationships: relationships, nextCursor: nextCursor, totalCount: totalCount)
        }
    }

    public func blocks() throws -> [V2ClientUserBlockProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT target_user_id, is_blocked, updated_at FROM v2_user_block_projections WHERE is_blocked = 1 ORDER BY target_user_id").map(Self.decodeBlockProjection)
        }
    }

    public func strangerMessagePreference() throws -> V2ClientStrangerMessagePreference? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT allows_stranger_messages, updated_at FROM v2_stranger_message_preference WHERE singleton = 1") else { return nil }
            return .init(allowsStrangerMessages: row["allows_stranger_messages"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    public func userAddPreference() throws -> V2ClientUserAddPreference? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT allows_being_added, updated_at FROM v2_user_add_preference WHERE singleton = 1") else { return nil }
            return .init(allowsBeingAdded: row["allows_being_added"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    public func directReadReceipt(roomID: RoomID) throws -> V2DirectReadReceiptProjection? {
        try databasePool.read { db -> V2DirectReadReceiptProjection? in
            guard let row = try Row.fetchOne(db, sql: "SELECT room_id, reader_user_id, read_through_room_sequence, recorded_at FROM v2_direct_read_receipt_projections WHERE room_id = ? AND is_visible = 1 AND read_through_room_sequence > 0", arguments: [roomID.rawValue]) else { return nil }
            return try .init(roomID: .init(row["room_id"] as String), readerUserID: .init(row["reader_user_id"] as String), readThroughRoomSequence: try Self.storageUnsigned(row, column: "read_through_room_sequence"), recordedAt: Date(timeIntervalSince1970: row["recorded_at"] as Double), isVisible: true)
        }
    }
    public func readReceiptPreference() throws -> V2ReadReceiptPreferences? {
        try databasePool.read { db -> V2ReadReceiptPreferences? in
            guard let row = try Row.fetchOne(db, sql: "SELECT allows_direct_read_receipts, allows_group_read_receipts, updated_at FROM v2_read_receipt_preference WHERE singleton = 1") else { return nil }
            return .init(allowsDirectReadReceipts: row["allows_direct_read_receipts"], allowsGroupReadReceipts: row["allows_group_read_receipts"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    public func moderationActions() throws -> [V2ClientModerationProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at FROM v2_moderation_projections ORDER BY server_created_at, source_event_id").map(Self.decodeModerationProjection)
        }
    }

    public func roomControl(roomID: RoomID) throws -> V2ClientRoomControlProjection? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, room_id, room_sequence, actor_user_id, is_frozen, server_created_at FROM v2_room_control_projections WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeRoomControlProjection(row)
        }
    }

    public func roomProfile(roomID: RoomID) throws -> V2ClientRoomProfileProjection? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, room_id, title, owner_user_id, capacity_class, membership_revision, created_at FROM v2_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]) else { return nil }
            return try Self.decodeRoomProfileProjection(row)
        }
    }

    func roomProfiles() throws -> [V2ClientRoomProfileProjection] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_event_id, room_id, title, owner_user_id, capacity_class, membership_revision, created_at FROM v2_room_profile_projections ORDER BY created_at DESC, room_id").map(Self.decodeRoomProfileProjection)
        }
    }

    /// 读取本账号在某房间的已读水位。
    ///
    /// 该值是**有效水位**：同一账号其他设备的已读回执投影，与本设备已经入队（等待发送）
    /// 或已被服务端确认的回执，两者取较大值。进入房间时本地推进无需等待网络往返即可把
    /// 未读清零，重试期间也不会退化。
    ///
    /// 未读数本身由服务端摘要给出；本访问器只回答"我已经读到哪个房间序号"。
    ///
    /// - Parameter roomID: 目标房间。
    /// - Returns: 已读水位；该房间尚无记录时为 nil。
    /// - Throws: 本地数据库读取失败。
    public func roomReadWatermark(roomID: RoomID) throws -> UInt64? {
        try roomReadWatermarks(roomIDs: [roomID])[roomID]
    }

    /// 批量读取若干房间的有效已读水位。
    ///
    /// 一次会话列表刷新只查一次：投影表按主键点查，本设备待发送与已确认的回执按房间取
    /// 较大值。归档只停止服务器核对，仍保留本设备阅读位置；不作为服务器已读证明。
    /// 被拒绝的回执不计入，否则一次越界的上报就会永久压低未读。
    ///
    /// - Parameter roomIDs: 目标房间，调用方需传入有界集合。
    /// - Returns: 有水位记录的房间到水位的映射；没有记录的房间不出现。
    /// - Throws: 本地数据库读取失败。
    public func roomReadWatermarks(roomIDs: [RoomID]) throws -> [RoomID: UInt64] {
        guard !roomIDs.isEmpty else { return [:] }
        let identifiers = roomIDs.map(\.rawValue)
        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ", ")
        return try databasePool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT room_id, CASE WHEN MIN(CASE WHEN typeof(value) = 'integer' AND value > 0
                        THEN 1 ELSE 0 END) = 1 THEN MAX(value) ELSE NULL END AS value FROM (
                        SELECT room_id, read_through_room_sequence AS value
                        FROM v2_room_read_watermarks
                        WHERE room_id IN (\(placeholders))
                        UNION ALL
                        SELECT room_id,desired_sequence AS value FROM v2_read_receipt_intents WHERE room_id IN (\(placeholders))
                        UNION ALL
                        SELECT room_id,requested_sequence AS value FROM v2_read_receipt_archives WHERE room_id IN (\(placeholders))
                        UNION ALL
                        SELECT r.room_id,r.requested_sequence AS value FROM v2_read_receipt_operations r
                        JOIN v2_operation_work w ON w.work_id=r.work_id
                        WHERE r.room_id IN (\(placeholders)) AND w.execution_state NOT IN ('rejected','closed','cancelledLocally','expiredUnsubmitted')
                    )
                    GROUP BY room_id
                    """,
                arguments: StatementArguments(identifiers + identifiers + identifiers + identifiers)
            )
            var watermarks: [RoomID: UInt64] = [:]
            for row in rows {
                let stored: String = row["room_id"]
                guard let roomID = try? RoomID(stored) else { continue }
                watermarks[roomID] = try Self.storageUnsigned(row, column: "value")
            }
            return watermarks
        }
    }

    /// 缓存当前用户打开私聊前显式解析出的身份。
    ///
    /// 它在同步重置后保留原房间与目标身份的关联；读取时权威
    /// direct_room_profile 投影优先。缓存和永久创建回执均不授予当前
    /// 房间访问权限，也不能替代资料展示所需的当前授权。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - publicIdentity: 已解析的公开身份。
    ///   - updatedAt: 缓存时刻，默认当前时间。
    /// - Throws: 数据库写入失败时抛出。
    public func cacheDirectRoomIdentity(roomID: RoomID, publicIdentity: V2PublicIdentity, roomCreatedAt: Date, updatedAt: Date = Date()) throws {
        guard roomCreatedAt.timeIntervalSince1970.isFinite, roomCreatedAt.timeIntervalSince1970 >= 0,
              updatedAt.timeIntervalSince1970.isFinite else { throw V2ClientProjectionError.invalidMessagePayload }
        try databasePool.write { db in
            try Self.cacheDirectRoomIdentity(roomID:roomID,publicIdentity:publicIdentity,roomCreatedAt:roomCreatedAt,updatedAt:updatedAt,db:db)
        }
    }

    static func cacheDirectRoomIdentity(roomID:RoomID,publicIdentity:V2PublicIdentity,roomCreatedAt:Date,updatedAt:Date,db:Database) throws {
        try Self.requireProjectionWritesUnfenced(db: db)
        if let existing = try Row.fetchOne(db, sql: "SELECT target_user_id, room_created_at FROM v2_direct_room_identities WHERE room_id = ?", arguments: [roomID.rawValue]) {
            let targetUserID: String = existing["target_user_id"]
            guard targetUserID == publicIdentity.userID.rawValue,
                  (existing["room_created_at"] as Double) == roomCreatedAt.timeIntervalSince1970 else { throw V2ClientProjectionError.invalidMessagePayload }
        }
        if let created = try Double.fetchOne(db, sql: "SELECT room_created_at FROM v2_direct_room_profile_projections WHERE room_id = ?", arguments: [roomID.rawValue]),
           created != roomCreatedAt.timeIntervalSince1970 { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(
            sql: """
            INSERT INTO v2_direct_room_identities
                (room_id, target_user_id, public_handle, display_name, account_kind, updated_at, room_created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET
                public_handle = excluded.public_handle,
                display_name = excluded.display_name,
                account_kind = excluded.account_kind,
                updated_at = excluded.updated_at
            """,
            arguments: [
                roomID.rawValue,
                publicIdentity.userID.rawValue,
                publicIdentity.handle.rawValue,
                publicIdentity.displayName,
                publicIdentity.accountKind.rawValue,
                updatedAt.timeIntervalSince1970,
                roomCreatedAt.timeIntervalSince1970
            ]
        )
        // This records the original creation result only. Room event authorization
        // is owned by current sync/query projections, never by a permanent receipt.
    }

    func directRoomIdentities() throws -> [V2ClientDirectRoomIdentity] {
        try databasePool.read { db in
            let cached = try Row.fetchAll(
                db,
                sql: "SELECT room_id, target_user_id, public_handle, display_name, account_kind, updated_at, room_created_at FROM v2_direct_room_identities ORDER BY updated_at DESC, room_id"
            ).map(Self.decodeDirectRoomIdentity)
            let projected = try Row.fetchAll(
                db,
                sql: "SELECT room_id, target_user_id, public_handle, display_name, account_kind, updated_at, room_created_at FROM v2_direct_room_profile_projections ORDER BY updated_at DESC, room_id"
            ).map(Self.decodeDirectRoomIdentity)
            return Dictionary(projected.map { ($0.roomID, $0) }, uniquingKeysWith: { _, incoming in incoming })
                .merging(Dictionary(cached.map { ($0.roomID, $0) }, uniquingKeysWith: { _, incoming in incoming }), uniquingKeysWith: { projected, _ in projected })
                .values
                .sorted { $0.roomCreatedAt == $1.roomCreatedAt ? $0.roomID.rawValue < $1.roomID.rawValue : $0.roomCreatedAt > $1.roomCreatedAt }
        }
    }

    /// 读取最后一次已授权的资料表示。
    ///
    /// 调用方必须通过 `V2ProfileResolver` 解析它，不得把其中的动态展示数据复制进
    /// 消息或会话结构。
    ///
    /// - Parameter userID: 目标用户。
    /// - Returns: 资料视图；本地不存在时返回 `nil`。
    /// - Throws: 数据库读取失败时抛出。
    public func profileView(userID: UserID) throws -> V2ProfileView? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id = ?",
                arguments: [userID.rawValue]
            ) else { return nil }
            let profile = try Self.decodeProfileView(row)
            return try Self.profileSurvivesSecurityFloor(profile, db: db) ? profile : nil
        }
    }

    public func profileViews(userIDs: [UserID]) throws -> [UserID: V2ProfileView] {
        let uniqueIDs = Array(Set(userIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return [:] }
        return try databasePool.read { db in
            let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM v2_profile_views WHERE user_id IN (\(placeholders))",
                arguments: StatementArguments(uniqueIDs.map(\.rawValue))
            )
            return try Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                let view = try Self.decodeProfileView(row)
                return try Self.profileSurvivesSecurityFloor(view, db: db) ? (view.userID, view) : nil
            })
        }
    }

    /// 保存资料视图。
    ///
    /// 只有在拿到完整授权服务端响应时才允许调用。安全版本下限保留，
    /// 因此后续迟到的旧响应不能在本地清理后重新恢复资料。
    ///
    /// - Parameter profile: 待保存资料。
    /// - Throws: 数据库写入失败时抛出。
    public func saveProfileView(_ profile: V2ProfileView) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            try Self.persist(profile, db: db)
        }
    }

    /// 标记资料不可用。
    ///
    /// 直接删除不可访问的视图，而不是在本地账号投影中保留旧资料；
    /// 图像缓存在更高的媒体边界观察到同一信号，必须同时清除受保护的头像字节。
    ///
    /// - Parameter userID: 目标用户。
    /// - Throws: 数据库写入失败时抛出。
    public func markProfileUnavailable(userID: UserID) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            try db.execute(sql: "DELETE FROM v2_profile_views WHERE user_id = ?", arguments: [userID.rawValue])
        }
    }

    /// 在单个 SQLite 事务内应用一批已授权的服务端结果。
    ///
    /// 因此崩溃后要么暴露上一代资料，要么暴露完整的新响应，
    /// 绝不会出现只补齐了一部分联系人的页面。
    ///
    /// - Parameter results: 服务端返回的查询结果。
    /// - Throws: 数据库写入失败时抛出。
    public func applyProfileViewResults(_ results: [V2ProfileViewLookupResult]) throws {
        try databasePool.write { db in
            try Self.requireProjectionWritesUnfenced(db: db)
            let batch = V2ProfileViewResultBatch(results)
            for profile in batch.profiles.values {
                try Self.persist(profile, db: db)
            }
            for userID in batch.unavailableUserIDs.subtracting(batch.profiles.keys) {
                try db.execute(sql: "DELETE FROM v2_profile_views WHERE user_id = ?", arguments: [userID.rawValue])
            }
        }
    }

    public func pendingProfileInvalidations(limit: Int) throws -> [V2ProfileInvalidation] {
        guard limit > 0 else { return [] }
        return try databasePool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT user_id, minimum_revision FROM v2_profile_invalidations AS invalidation
                    WHERE NOT EXISTS (SELECT 1 FROM v2_profile_views AS profile
                        WHERE profile.user_id = invalidation.user_id AND profile.revision > invalidation.minimum_revision)
                      AND NOT EXISTS (SELECT 1 FROM v2_local_profile_display AS display
                        WHERE display.user_id = invalidation.user_id AND display.profile_revision > invalidation.minimum_revision)
                    ORDER BY updated_at, user_id LIMIT ?
                    """,
                arguments: [limit]
            ).map { row in
                guard let revision = V2ProfileRevision(rawValue: try Self.storageUnsigned(row, column: "minimum_revision")) else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
                return try .init(userID: .init(row["user_id"] as String), minimumRevision: revision)
            }
        }
    }


    private static func validateOrdering(_ records: [V2ClientSyncRecord]) throws {
        for pair in zip(records, records.dropFirst()) where pair.1.sequence <= pair.0.sequence {
            throw V2ClientSyncError.invalidRecordOrdering
        }
    }

    /// 把无符号整数转换为本地可持久化的有符号整数。
    ///
    /// PostgreSQL 的 `BIGINT` 与 SQLite 的 `INTEGER` 都是有符号类型；
    /// 更宽的协议 `uint64` 域止步于传输边界，任何取值在进入本地持久化状态之前都必须通过失败关闭。
    ///
    /// - Parameter value: 待转换的无符号整数。
    /// - Returns: 对应的有符号整数。
    /// - Throws: 超出 `Int64` 表示范围时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    static func storageInteger(_ value: UInt64) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw V2ClientSyncError.storageRangeExceeded
        }
        return result
    }

    /// Decode the actual SQLite integer storage class before converting it.
    /// Signed values are retained so each caller can apply its domain checks.
    static func storageInteger(_ row: Row, column: String) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage else {
            throw V2ClientSyncError.storageRangeExceeded
        }
        return integer
    }

    static func storageUnsigned(_ row: Row, column: String) throws -> UInt64 {
        try storageUnsigned(storageInteger(row, column: column))
    }

    static func storageUnsigned(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else { throw V2ClientSyncError.storageRangeExceeded }
        return UInt64(value)
    }

    static func commandStorageInteger(_ value: UInt64) throws -> Int64 {
        guard let result = Int64(exactly: value) else {
            throw V2ClientCommandError.commandConflict
        }
        return result
    }

    static func commandStorageUnsigned(_ value: Int64) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else { throw V2ClientCommandError.commandConflict }
        return result
    }

    static func commandStorageInteger(_ row: Row, column: String) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage, integer >= 0 else {
            throw V2ClientCommandError.commandConflict
        }
        return integer
    }

    static func commandStorageUnsigned(_ row: Row, column: String) throws -> UInt64 {
        UInt64(try commandStorageInteger(row, column: column))
    }

    private static func projectionStorageUnsigned(_ row: Row, column: String) throws -> UInt64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try projectionStorageUnsigned(integer)
    }

    private static func projectionStorageUnsigned(_ value: Int64) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else { throw V2ClientProjectionError.invalidMessagePayload }
        return result
    }

    /// Personal cursors/snapshots never carry public room content. Both direct
    /// and group conversations recover that content through the room log.
    private static func requirePersonalProjection(_ kind: String) throws {
        guard !["message", "message_reaction", "group_capability", "moderation"].contains(kind) else {
            throw V2ClientSyncError.unexpectedPersonalProjection(kind)
        }
    }

    private static func validatePersistable(_ batch: V2ClientSyncBatch) throws {
        _ = try storageInteger(batch.generation)
        for record in batch.records {
            try requirePersonalProjection(record.projectionKind)
            _ = try storageInteger(record.sequence)
        }
    }

    private static func validatePersistable(_ manifest: V2ClientSnapshotManifest) throws {
        _ = try storageInteger(manifest.reset.generation)
        _ = try storageInteger(manifest.reset.baseSequence)
    }

    private static func matchesExisting(_ record: V2ClientSyncRecord, db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT source_event_id, projection_kind, payload FROM v2_sync_events WHERE sequence = ?", arguments: [try storageInteger(record.sequence)]) else { return false }
        let eventID: String = row["source_event_id"]
        let kind: String = row["projection_kind"]
        let payload: Data = row["payload"]
        return eventID == record.sourceEventID.rawValue && kind == record.projectionKind && payload == record.payload
    }

    private static func establishInstallationBinding(_ binding: V2LocalInstallationBinding, userID: UserID?, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1") {
            let stored: String = row["binding"]
            let storedUserID: String? = row["user_id"]
            guard stored == binding.value.uuidString,
                  userID == nil || storedUserID == nil || storedUserID == userID?.rawValue
            else { throw V2ClientLocalStorageError.installationBindingMismatch }
            if storedUserID == nil, let userID {
                try db.execute(sql: "UPDATE v2_local_installation SET user_id = ? WHERE singleton = 1", arguments: [userID.rawValue])
            }
            return
        }
        try db.execute(sql: "INSERT INTO v2_local_installation (singleton, binding, user_id) VALUES (1, ?, ?)", arguments: [binding.value.uuidString, userID?.rawValue])
    }

    private static func matchesSnapshotImport(_ manifest: V2ClientSnapshotManifest, db: Database) throws -> Bool {
        try validatePersistable(manifest)
        guard let row = try Row.fetchOne(db, sql: "SELECT snapshot_id, generation, base_sequence, root_digest, next_sync_token, receipt, capability_profile, page_count, total_items, total_bytes FROM v2_snapshot_import LIMIT 1") else {
            return false
        }
        let snapshotID: String = row["snapshot_id"]
        let generation = try storageInteger(row, column: "generation")
        let baseSequence = try storageInteger(row, column: "base_sequence")
        let digest: String = row["root_digest"]
        let token: String = row["next_sync_token"]
        let receipt: String = row["receipt"]
        let profile: String = row["capability_profile"]
        let pageCount = try storageInteger(row, column: "page_count")
        let totalItems = try storageInteger(row, column: "total_items")
        let totalBytes = try storageInteger(row, column: "total_bytes")
        let expectedGeneration = try storageInteger(manifest.reset.generation)
        let expectedBaseSequence = try storageInteger(manifest.reset.baseSequence)
        let expectedTotalItems = try storageInteger(manifest.totalItems)
        let expectedTotalBytes = try storageInteger(manifest.totalBytes)
        return snapshotID == manifest.reset.snapshotID.rawValue &&
            generation == expectedGeneration &&
            baseSequence == expectedBaseSequence &&
            digest == manifest.rootDigest &&
            token == manifest.nextSyncToken.rawValue &&
            receipt == manifest.receipt.rawValue &&
            profile == manifest.capabilityProfile &&
            pageCount == Int64(manifest.pageCount) &&
            totalItems == expectedTotalItems &&
            totalBytes == expectedTotalBytes
    }

    static func readCursor(_ db: Database) throws -> V2LocalSyncCursor? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_sync_cursor WHERE singleton = 1") else { return nil }
        let state = try V2LocalSyncCursor.State(rawValue: row["state"] as String).unwrap(or: V2ClientSyncError.generationMismatch)
        let generation = try storedCursorSequence(row["generation"])
        let applied = try storedCursorSequence(row["applied_sequence"])
        let acknowledged = try storedCursorSequence(row["server_acknowledged_sequence"])
        let token = try (row["sync_token"] as String?).map(V2SyncToken.init)
        let pendingReceipt = try (row["pending_ack_receipt"] as String?).map(V2SyncReceipt.init)
        let pendingValue: DatabaseValue = row["pending_ack_sequence"]
        let pendingSequence = try pendingValue.isNull ? nil : storedCursorSequence(pendingValue)
        if state == .ready {
            return try .init(
                state: state,
                generation: generation,
                appliedSequence: applied,
                serverAcknowledgedSequence: acknowledged,
                syncToken: token,
                pendingAcknowledgementReceipt: pendingReceipt,
                pendingAcknowledgementSequence: pendingSequence,
                pendingReset: nil
            )
        }
        guard let snapshotRaw: String = row["pending_snapshot_id"],
              !(row["pending_base_sequence"] as DatabaseValue).isNull,
              let expires: Double = row["pending_expires_at"]
        else { throw V2ClientSyncError.resetFenceMismatch }
        return try .init(
            state: state,
            generation: generation,
            appliedSequence: applied,
            serverAcknowledgedSequence: acknowledged,
            syncToken: token,
            pendingAcknowledgementReceipt: nil,
            pendingAcknowledgementSequence: nil,
            pendingReset: .init(snapshotID: .init(snapshotRaw), generation: generation, baseSequence: try storedCursorSequence(row["pending_base_sequence"]), expiresAt: Date(timeIntervalSince1970: expires))
        )
    }

    private static func storedCursorSequence(_ value: DatabaseValue) throws -> UInt64 {
        guard case .int64(let stored) = value.storage else { throw V2ClientSyncError.storageRangeExceeded }
        return try storageUnsigned(stored)
    }

    private static func writeCursor(_ cursor: V2LocalSyncCursor, db: Database) throws {
        let reset = cursor.pendingReset
        try db.execute(
            sql: """
            INSERT INTO v2_sync_cursor
                (singleton, state, generation, applied_sequence, server_acknowledged_sequence,
                 sync_token, pending_ack_receipt, pending_ack_sequence,
                 pending_snapshot_id, pending_base_sequence, pending_expires_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET state = excluded.state, generation = excluded.generation,
                applied_sequence = excluded.applied_sequence, server_acknowledged_sequence = excluded.server_acknowledged_sequence,
                sync_token = excluded.sync_token, pending_ack_receipt = excluded.pending_ack_receipt,
                pending_ack_sequence = excluded.pending_ack_sequence,
                pending_snapshot_id = excluded.pending_snapshot_id, pending_base_sequence = excluded.pending_base_sequence,
                pending_expires_at = excluded.pending_expires_at
            """,
            arguments: [cursor.state.rawValue, try storageInteger(cursor.generation), try storageInteger(cursor.appliedSequence), try storageInteger(cursor.serverAcknowledgedSequence), cursor.syncToken?.rawValue, cursor.pendingAcknowledgementReceipt?.rawValue, try cursor.pendingAcknowledgementSequence.map(storageInteger), reset?.snapshotID.rawValue, try reset.map { try storageInteger($0.baseSequence) }, reset?.expiresAt.timeIntervalSince1970]
        )
    }

    private static func decodeEvent(_ row: Row) throws -> V2ClientSyncRecord {
        try .init(sequence: storageUnsigned(row, column: "sequence"), sourceEventID: .init(row["source_event_id"] as String), projectionKind: row["projection_kind"], payload: row["payload"])
    }

    private static func decodeConversationState(_ row: Row) throws -> V2ClientConversationState {
        let muteUntil: Double = row["mute_until"]
        return try .init(
            roomID: .init(row["room_id"] as String),
            isPinned: row["is_pinned"],
            isArchived: row["is_archived"],
            muteUntil: muteUntil == 0 ? nil : Date(timeIntervalSince1970: muteUntil),
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
            revision: V2PersonalPreferenceRevision(rawValue: UInt64(row["revision"] as Int64))!
        )
    }

    static func decodeProfileView(_ row: Row) throws -> V2ProfileView {
        let userID = try UserID(row["user_id"] as String)
        guard let state = V2ProfileState(rawValue: row["state"] as String),
              let revision = V2ProfileRevision(rawValue: try storageUnsigned(row, column: "revision")),
              let visibilityRevision = V2ProfileRevision(rawValue: try storageUnsigned(row, column: "visibility_revision"))
        else { throw V2ClientProjectionError.invalidMessagePayload }
        let handle: String? = row["public_handle"]
        let displayName: String? = row["display_name"]
        let accountKindRaw: String? = row["account_kind"]
        let accountKind = accountKindRaw.flatMap(V2AccountKind.init)
        guard accountKindRaw == nil || accountKind != nil else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let avatarMediaID: String? = row["avatar_media_id"]
        let identity: V2PublicIdentity?
        switch (handle, displayName, accountKind) {
        case (.none, .none, .none): identity = nil
        case let (.some(handle), .some(displayName), .some(accountKind)):
            identity = try .init(userID: userID, handle: .init(handle), displayName: displayName, accountKind: accountKind)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
        let avatar = try avatarMediaID.map { try V2AvatarReference(mediaID: .init($0)) }
        return try .init(
            userID: userID,
            publicIdentity: identity,
            avatar: avatar,
            state: state,
            revision: revision,
            visibilityRevision: visibilityRevision
        )
    }

    static func decodeRelationshipProjection(_ row: Row) throws -> V2ClientRelationshipProjection {
        guard let state = V2RelationshipState(rawValue: row["state"] as String) else { throw V2ClientSocialProjectionError.invalidPayload }
        let requestedBy = try (row["requested_by_user_id"] as String?).map(UserID.init)
        guard (state == .pending) == (requestedBy != nil) else { throw V2ClientSocialProjectionError.invalidPayload }
        return try .init(targetUserID: .init(row["target_user_id"] as String), state: state, requestedByUserID: requestedBy, updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }

    private static func decodeBlockProjection(_ row: Row) throws -> V2ClientUserBlockProjection {
        try .init(targetUserID: .init(row["target_user_id"] as String), isBlocked: row["is_blocked"], updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double))
    }

    private static func applyMessage(_ record: V2ClientSyncRecord, expectedRoomID: RoomID, expectedRoomSequence: UInt64, db: Database) throws {
        let effect = try V2LocalMessageEffect(record: record)
        guard effect.roomID == expectedRoomID else { throw V2ClientProjectionError.invalidMessagePayload }
        if case .accepted(let message) = effect, message.roomSequence != expectedRoomSequence {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        if case .edited(let edit) = effect,
           case .complete(let replacement) = edit.content, replacement.mutationRoomSequence != expectedRoomSequence {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        guard try claimMessageEffect(effect, sourceEventID: record.sourceEventID, db: db) else { return }
        switch effect {
        case .accepted(let value): try persist(value, db: db)
        case .edited(let value): try persist(value, db: db)
        case .withdrawn(let value), .redacted(let value): try persist(value, db: db)
        }
    }

    /// 为一条消息效果登记认领。
    ///
    /// 账号绑定的数据库就是该效果的账号作用域。认领标记、投影变更、全文检索任务与消费游标
    /// 共享同一次写入事务，因此应用失败不会留下已提交的认领记录。
    ///
    /// - Parameters:
    ///   - effect: 待应用的消息效果。
    ///   - sourceEventID: 来源事件标识。
    ///   - db: 当前写入事务。
    /// - Returns: 首次认领时为 `true`；重复应用时返回 `false`。
    /// - Throws: 数据库读写失败时抛出。
    private static func claimMessageEffect(_ effect: V2LocalMessageEffect, sourceEventID: EventID, db: Database) throws -> Bool {
        let digest = try effect.digest()
        let revision = try storageInteger(effect.revision)
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, message_revision, canonical_digest FROM v2_message_effects WHERE source_event_id = ? AND projection_kind = 'message' AND entity_key = ?", arguments: [sourceEventID.rawValue, effect.messageID.rawValue]) {
            guard (row["room_id"] as String) == effect.roomID.rawValue,
                  (try storageInteger(row, column: "message_revision")) == revision,
                  (row["canonical_digest"] as Data) == digest
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return false
        }
        try db.execute(sql: "INSERT INTO v2_message_effects (source_event_id, projection_kind, entity_key, room_id, message_revision, canonical_digest) VALUES (?, 'message', ?, ?, ?, ?)", arguments: [sourceEventID.rawValue, effect.messageID.rawValue, effect.roomID.rawValue, revision, digest])
        return true
    }

    private static func isRevokedRoomRecord(_ record: V2ClientSyncRecord, db: Database) throws -> Bool {
        guard record.projectionKind != "room", record.projectionKind != "membership" else { return false }
        struct Scope: Decodable { let room_id: String? }
        guard let value = try? JSONDecoder().decode(Scope.self, from: record.payload), let rawRoom = value.room_id else { return false }
        let room = try RoomID(rawRoom)
        return try Bool.fetchOne(db, sql: "SELECT is_member = 0 FROM v2_room_membership_states WHERE room_id = ?", arguments: [room.rawValue]) == true
    }

    private static func applyRoomEventProjection(_ record: V2ClientSyncRecord, roomID: RoomID, db: Database) throws {
        struct RoomHeader: Decodable { let room_id: String }
        guard ["message", "message_reaction", "moderation", "room", "membership", "group_capability"].contains(record.projectionKind),
              let header = try? JSONDecoder().decode(RoomHeader.self, from: record.payload),
              let payloadRoom = try? RoomID(header.room_id), payloadRoom == roomID
        else { throw V2ClientProjectionError.invalidMessagePayload }
        if try isRevokedRoomRecord(record, db: db) { return }
        switch record.projectionKind {
        case "message": try applyMessage(record, expectedRoomID: roomID, expectedRoomSequence: record.sequence, db: db)
        case "message_reaction":
            try applyReaction(record, expectedRoomSequence: record.sequence, db: db)
        case "moderation": try applyModeration(record, expectedRoomID: roomID, db: db)
        case "room", "membership": try applyMembershipAwareRoomProjection(record, expectedRoomID: roomID, expectedRoomSequence: record.sequence, db: db)
        case "group_capability": try applyGroupCapability(record, expectedRoomSequence: record.sequence, expectedRoomID: roomID, db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyMembershipAwareRoomProjection(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, expectedRoomID: RoomID? = nil, expectedRoomSequence: UInt64? = nil, db: Database) throws {
        struct MembershipHeader: Decodable {
            let roomID: String
            let membershipRevision: Int64
            let eventType: String
            let targetUserID: String?
            let action: String?
            let viewerMembershipRevision: Int64?
            let viewerIsMember: Bool?
            let viewerMembershipSource: String?
            enum CodingKeys: String, CodingKey {
                case targetUserID = "target_user_id", action
                case roomID = "room_id", membershipRevision = "membership_revision", eventType = "event_type"
                case viewerMembershipRevision = "viewer_membership_revision"
                case viewerIsMember = "viewer_is_member"
                case viewerMembershipSource = "viewer_membership_source_event_id"
            }
        }
        let header: MembershipHeader
        do { header = try JSONDecoder().decode(MembershipHeader.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        let roomID = try RoomID(header.roomID)
        guard expectedRoomID == nil || expectedRoomID == roomID else { throw V2ClientProjectionError.invalidMessagePayload }
        let memberEffect = record.projectionKind == "membership"
            ? try V2LocalMemberEffect(record: record, expectedRoomID: expectedRoomID, expectedRoomSequence: expectedRoomSequence) : nil
        guard header.membershipRevision > 0,
              header.eventType == (record.projectionKind == "room" ? "room.created" : "membership_changed") else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let currentUserID: String? = try Row.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton = 1")?["user_id"]
        let affectedUser = try header.targetUserID.map(UserID.init)
        if record.projectionKind == "membership" {
            guard affectedUser != nil, header.action == "add" || header.action == "remove" else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
        }
        let table = target.table("v2_room_membership_states")
        let prior = try Row.fetchOne(db, sql: "SELECT membership_revision, source_event_id, is_member FROM \(table) WHERE room_id = ?", arguments: [roomID.rawValue])
        let priorRevision = try prior.map { try effectInteger($0, "membership_revision") } ?? 0
        let priorIsMember: Bool = prior?["is_member"] ?? true
        let isOwnEvent = record.projectionKind == "room" || affectedUser?.rawValue == currentUserID
        var ownRevision = isOwnEvent ? header.membershipRevision : nil
        var ownSource = record.sourceEventID.rawValue
        var isMember = header.action != "remove" || !isOwnEvent
        // Only snapshot state has an authoritative viewer revision carried across unrelated member changes.
        if case .snapshotShadow = target, let revision = header.viewerMembershipRevision {
            guard revision > 0, let member = header.viewerIsMember, let source = header.viewerMembershipSource else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            ownRevision = revision; ownSource = try EventID(source).rawValue; isMember = member
        }
        if let revision = ownRevision {
            if revision < priorRevision { return }
            if revision == priorRevision {
                guard (prior?["source_event_id"] as String?) == ownSource, priorIsMember == isMember else {
                    throw V2ClientProjectionError.invalidMessagePayload
                }
                // Replaying a grant must not recreate a room removed by an authoritative snapshot.
                if case .live = target, try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM v2_room_profile_projections WHERE room_id = ?)", arguments: [roomID.rawValue]) != true { return }
            } else {
                try db.execute(sql: "INSERT INTO \(table) (room_id, membership_revision, source_event_id, is_member) VALUES (?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET membership_revision = excluded.membership_revision, source_event_id = excluded.source_event_id, is_member = excluded.is_member", arguments: [roomID.rawValue, revision, ownSource, isMember])
            }
            if !isMember {
                try purgeRoomProjection(roomID: roomID.rawValue, target: target, db: db)
                return
            }
        } else {
            if !priorIsMember { return }
        }
        if let memberEffect { try applyMemberEffect(memberEffect, target: target, db: db) }
        if ownRevision == nil {
            if let profile = try Row.fetchOne(db, sql: "SELECT membership_revision FROM \(target.table("v2_room_profile_projections")) WHERE room_id = ?", arguments: [roomID.rawValue]),
               try effectInteger(profile, "membership_revision") > header.membershipRevision { return }
        }
        try persist(V2ClientRoomProfileProjection(record: record), target: target, db: db)
        if case .live = target, let revision = ownRevision, revision > priorRevision, isMember {
            try enqueueGrantedRoomRecovery(roomID: roomID, db: db)
        }
    }

    private static func purgeRoomProjection(roomID: String, target: ProjectionTableTarget = .live, db: Database) throws {
        if case .live = target {
            // Remove authorization-dependent recovery before deleting display
            // projections. State deletion also invalidates cached summaries;
            // removing work last prevents invalidation from resurrecting it.
            try db.execute(sql: "DELETE FROM v2_room_sync_states WHERE room_id = ?", arguments: [roomID])
            try db.execute(sql: "DELETE FROM v2_room_latest_visible WHERE room_id = ?", arguments: [roomID])
            try db.execute(sql: "DELETE FROM v2_room_recovery_work WHERE room_id = ?", arguments: [roomID])
            let messageIDs = try String.fetchAll(db, sql: "SELECT message_id FROM v2_message_projections WHERE room_id = ?", arguments: [roomID])
            for messageID in messageIDs { try enqueueMessageSearchDeletionJob(messageID: messageID, db: db) }
        }
        for table in [
            "v2_message_reactions", "v2_reaction_versions", "v2_reaction_effects", "v2_message_effects", "v2_message_tombstones", "v2_message_projections",
            "v2_moderation_projections", "v2_room_control_projections", "v2_room_profile_projections",
            "v2_conversation_states", "v2_message_favorites", "v2_timeline_activity_projections",
            "v2_group_pinned_messages", "v2_pin_effects", "v2_group_announcements", "v2_announcement_effects", "v2_group_avatar_invalidations", "v2_group_avatar_effects", "v2_group_nickname_invalidations", "v2_group_nickname_effects", "v2_group_role_policies", "v2_role_policy_effects", "v2_group_role_policy_baselines", "v2_role_policy_recovery_requests",
            "v2_group_member_roles", "v2_member_effects", "v2_group_permission_revisions", "v2_group_events",
            "v2_group_event_cursors", "v2_conversation_summaries", "v2_conversation_list_entries",
        ] {
            if case .snapshotShadow = target, !snapshotOrdinaryBankTables.contains(table) { continue }
            try db.execute(sql: "DELETE FROM \(target.table(table)) WHERE room_id = ?", arguments: [roomID])
        }
    }

    private static func pinShouldReplace(
        _ current: Row, source: String, sequence: Int64, digest: Data,
        isPinned: Bool, updatedAt: Double
    ) throws -> Bool {
        let oldSource: String? = current["source_event_id"]
        let oldSequence = try effectInteger(current, "room_sequence")
        guard oldSource != nil, (current["canonical_digest"] as Data?) != nil else { throw V2ClientProjectionError.invalidMessagePayload }
        if source == oldSource {
            guard (current["canonical_digest"] as Data?) == digest,
                  (current["is_pinned"] as Bool) == isPinned,
                  (current["updated_at"] as Double) == updatedAt,
                  sequence == oldSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return false
        }
        guard oldSequence != sequence else { throw V2ClientProjectionError.invalidMessagePayload }
        return sequence > oldSequence
    }

    private static func applyPinnedMessage(
        _ effect: V2LocalPinnedMessageEffect,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let receipts = target.table("v2_pin_effects")
        let pins = target.table("v2_group_pinned_messages")
        let sequence = effect.roomSequence
        let receipt = try Row.fetchOne(db, sql: "SELECT * FROM \(receipts) WHERE source_event_id = ? AND room_id = ?", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue])
        if let receipt {
            let oldSequence = try effectInteger(receipt, "room_sequence")
            guard (receipt["message_id"] as String) == effect.messageID.rawValue,
                  (receipt["canonical_digest"] as Data) == effect.digest,
                  oldSequence == sequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
        } else {
            try db.execute(sql: "INSERT INTO \(receipts) (source_event_id, room_id, message_id, room_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.messageID.rawValue, sequence, effect.digest])
        }
        let updatedAt = Double(effect.updatedAtMilliseconds) / 1_000
        if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(pins) WHERE room_id = ? AND message_id = ?", arguments: [effect.roomID.rawValue, effect.messageID.rawValue]) {
            guard try pinShouldReplace(current, source: effect.sourceEventID.rawValue,
                sequence: sequence, digest: effect.digest, isPinned: effect.isPinned,
                updatedAt: updatedAt)
            else { return }
        }
        try db.execute(sql: """
            INSERT INTO \(pins) (room_id, message_id, is_pinned, room_sequence, updated_at, source_event_id, canonical_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id, message_id) DO UPDATE SET is_pinned = excluded.is_pinned,
                room_sequence = excluded.room_sequence, updated_at = excluded.updated_at,
                source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.messageID.rawValue, effect.isPinned, sequence, updatedAt, effect.sourceEventID.rawValue, effect.digest])
    }


    private static func preservePinnedMessagesInSnapshot(db: Database) throws {
        let pins = snapshotShadowTable(for: "v2_group_pinned_messages")
        let rooms = snapshotShadowTable(for: "v2_room_profile_projections")
        let receipts = snapshotShadowTable(for: "v2_pin_effects")
        // Check candidate receipts before SQL ordering can exclude a corrupt value.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT room_sequence FROM \(pins)
                    UNION ALL SELECT room_sequence FROM \(receipts)
                    UNION ALL
                    SELECT live.room_sequence FROM v2_pin_effects AS live
                    WHERE EXISTS (SELECT 1 FROM \(rooms) AS room
                        WHERE room.room_id = live.room_id AND room.is_group_event_authorized = 1)
                       OR EXISTS (SELECT 1 FROM \(pins) AS state
                        WHERE state.room_id = live.room_id AND state.message_id = live.message_id)
                       OR EXISTS (SELECT 1 FROM \(receipts) AS incoming
                        WHERE incoming.source_event_id = live.source_event_id AND incoming.room_id = live.room_id)
                ) WHERE typeof(room_sequence) <> 'integer' OR room_sequence <= 0
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT live.* FROM v2_group_pinned_messages AS live
            JOIN \(rooms) AS room ON room.room_id = live.room_id
            WHERE room.is_group_event_authorized = 1
            """)
        while let live = try rows.next() {
            let room: String = live["room_id"], message: String = live["message_id"]
            let sequence = try effectInteger(live, "room_sequence")
            guard let source = live["source_event_id"] as String?, let digest = live["canonical_digest"] as Data?
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(pins) WHERE room_id = ? AND message_id = ?", arguments: [room, message]) {
                guard try pinShouldReplace(current, source: source, sequence: sequence, digest: digest, isPinned: live["is_pinned"], updatedAt: live["updated_at"]) else { continue }
            }
            try db.execute(sql: """
                INSERT INTO \(pins) (room_id, message_id, is_pinned, room_sequence, updated_at, source_event_id, canonical_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id, message_id) DO UPDATE SET is_pinned = excluded.is_pinned,
                    room_sequence = excluded.room_sequence, updated_at = excluded.updated_at,
                    source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
                """, arguments: [room, message, live["is_pinned"] as Bool, sequence, live["updated_at"] as Double, source, digest])
        }
        // Only keep receipts covered by retained state. Removed rooms/items do
        // not carry independent historical proof into a new snapshot bank.
        let covered = "live.room_sequence <= state.room_sequence"
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_pin_effects AS live
                JOIN \(receipts) AS incoming ON incoming.source_event_id = live.source_event_id AND incoming.room_id = live.room_id
                WHERE (live.message_id <> incoming.message_id OR live.canonical_digest <> incoming.canonical_digest
                    OR live.room_sequence <> incoming.room_sequence)
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(receipts)
            SELECT live.* FROM v2_pin_effects AS live
            JOIN \(pins) AS state ON state.room_id = live.room_id AND state.message_id = live.message_id
            WHERE \(covered)
            ON CONFLICT(source_event_id, room_id) DO NOTHING
            """)
    }

    private static func effectInteger(_ row: Row, _ column: String) throws -> Int64 {
        let value: DatabaseValue = row[column]
        guard case .int64(let integer) = value.storage, integer > 0 else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return integer
    }

    private static func optionalEffectInteger(_ row: Row, _ column: String) throws -> Int64? {
        let value: DatabaseValue = row[column]
        return try value.isNull ? nil : effectInteger(row, column)
    }

    private static func applyAnnouncement(
        _ effect: V2LocalAnnouncementEffect,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let receipts = target.table("v2_announcement_effects")
        let announcements = target.table("v2_group_announcements")
        if let receipt = try Row.fetchOne(db, sql: "SELECT * FROM \(receipts) WHERE source_event_id = ? AND room_id = ?", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue]) {
            let sequence = try effectInteger(receipt, "room_sequence")
            guard (try effectInteger(receipt, "revision")) == effect.revision,
                  (receipt["canonical_digest"] as Data) == effect.digest,
                  sequence == effect.roomSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(receipts) (source_event_id, room_id, revision, room_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.revision, effect.roomSequence, effect.digest])
        let sequence = effect.roomSequence
        if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(announcements) WHERE room_id = ?", arguments: [effect.roomID.rawValue]) {
            let revision = try effectInteger(current, "revision")
            let currentSequence = try effectInteger(current, "room_sequence")
            if revision > effect.revision { return }
            if revision == effect.revision {
                let source: String? = current["source_event_id"]
                guard (current["body"] as String) == effect.body,
                      (current["updated_at"] as Double) == Double(effect.updatedAtMilliseconds) / 1_000,
                      source == effect.sourceEventID.rawValue && (current["canonical_digest"] as Data?) == effect.digest,
                      currentSequence == sequence
                else { throw V2ClientProjectionError.invalidMessagePayload }
            }
        }
        try db.execute(sql: """
            INSERT INTO \(announcements) (room_id, body, revision, room_sequence, updated_at, source_event_id, canonical_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET body = excluded.body, revision = excluded.revision,
                room_sequence = excluded.room_sequence, updated_at = excluded.updated_at,
                source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.body, effect.revision, sequence, Double(effect.updatedAtMilliseconds) / 1_000, effect.sourceEventID.rawValue, effect.digest])
    }


    private static func preserveRolePoliciesInSnapshot(db: Database) throws {
        let policies = snapshotShadowTable(for: "v2_group_role_policies")
        let rooms = snapshotShadowTable(for: "v2_room_profile_projections")
        let revisions = snapshotShadowTable(for: "v2_group_permission_revisions")
        // Validate both banks before ordering or MAX can hide an invalid value.
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT revision, room_sequence FROM \(policies)
                    UNION ALL
                    SELECT live.revision, live.room_sequence FROM v2_group_role_policies AS live
                    JOIN \(rooms) AS room ON room.room_id = live.room_id
                    WHERE room.is_group_event_authorized = 1
                    UNION ALL SELECT revision, NULL FROM \(revisions)
                    UNION ALL
                    SELECT live.revision, NULL FROM v2_group_permission_revisions AS live
                    JOIN \(rooms) AS room ON room.room_id = live.room_id
                    WHERE room.is_group_event_authorized = 1
                ) WHERE typeof(revision) <> 'integer' OR revision <= 0
                   OR (room_sequence IS NOT NULL AND (typeof(room_sequence) <> 'integer' OR room_sequence <= 0))
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        let rows = try Row.fetchAll(db, sql: """
            SELECT live.* FROM v2_group_role_policies AS live JOIN \(rooms) AS room ON room.room_id = live.room_id
            WHERE room.is_group_event_authorized = 1
            """)
        for live in rows {
            let room: String = live["room_id"]
            let role: String = live["role"]
            let revision = try effectInteger(live, "revision")
            var sequence = try optionalEffectInteger(live, "room_sequence")
            var source: String? = live["source_event_id"]
            var digest: Data? = live["canonical_digest"]
            if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(policies) WHERE room_id = ? AND role = ?", arguments: [room, role]) {
                let currentRevision = try effectInteger(current, "revision")
                let currentSequence = try optionalEffectInteger(current, "room_sequence")
                if currentRevision > revision { continue }
                if currentRevision == revision {
                    let currentSource: String? = current["source_event_id"]
                    guard (current["permissions"] as Data) == (live["permissions"] as Data),
                          currentSource == nil || source == nil || (currentSource == source && (current["canonical_digest"] as Data?) == digest),
                          sequence == nil || currentSequence == nil || sequence == currentSequence
                    else { throw V2ClientProjectionError.invalidMessagePayload }
                    source = source ?? currentSource
                    digest = digest ?? current["canonical_digest"]
                    sequence = sequence ?? currentSequence
                }
            }
            try db.execute(sql: """
                INSERT INTO \(policies) (room_id, role, permissions, revision, room_sequence, source_event_id, canonical_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_id, role) DO UPDATE SET permissions = excluded.permissions, revision = excluded.revision,
                    room_sequence = excluded.room_sequence, source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
                """, arguments: [room, role, live["permissions"] as Data, revision, sequence, source, digest])
        }
        // A role's independent ordering never lowers the global revision used
        // by commands, including when the other role is not locally known.
        try db.execute(sql: """
            INSERT INTO \(revisions) (room_id, revision)
            SELECT live.room_id, live.revision FROM v2_group_permission_revisions AS live
            JOIN \(rooms) AS room ON room.room_id = live.room_id
            WHERE room.is_group_event_authorized = 1
            ON CONFLICT(room_id) DO UPDATE SET revision = MAX(\(revisions).revision, excluded.revision)
            """)
    }

    private static func applyRolePolicy(
        _ effect: V2LocalRolePolicyEffect,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let receipts = target.table("v2_role_policy_effects")
        let policies = target.table("v2_group_role_policies")
        let revisions = target.table("v2_group_permission_revisions")
        if let current = try Row.fetchOne(db, sql: "SELECT revision FROM \(revisions) WHERE room_id = ?", arguments: [effect.roomID.rawValue]) {
            _ = try effectInteger(current, "revision")
        }
        if let receipt = try Row.fetchOne(db, sql: "SELECT * FROM \(receipts) WHERE source_event_id = ? AND room_id = ?", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue]) {
            let sequence = try effectInteger(receipt, "room_sequence")
            guard (receipt["role"] as String) == effect.role.rawValue,
                  (try effectInteger(receipt, "revision")) == effect.revision,
                  (receipt["canonical_digest"] as Data) == effect.digest,
                  sequence == effect.roomSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(receipts) (source_event_id, room_id, role, revision, room_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, effect.roomID.rawValue, effect.role.rawValue, effect.revision, effect.roomSequence, effect.digest])
        if let baseline = try Row.fetchOne(db, sql: "SELECT * FROM \(target.table("v2_group_role_policy_baselines")) WHERE room_id = ?", arguments: [effect.roomID.rawValue]), (try effectInteger(baseline, "permission_revision")) >= effect.revision {
            if (try effectInteger(baseline, "permission_revision")) == effect.revision {
                let column = effect.role == .admin ? "admin_permissions" : "member_permissions"
                guard (baseline[column] as Data) == effect.encodedPermissions else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            return
        }
        let sequence = effect.roomSequence
        if let current = try Row.fetchOne(db, sql: "SELECT * FROM \(policies) WHERE room_id = ? AND role = ?", arguments: [effect.roomID.rawValue, effect.role.rawValue]) {
            let revision = try effectInteger(current, "revision")
            let currentSequence = try effectInteger(current, "room_sequence")
            if revision > effect.revision { return }
            if revision == effect.revision {
                let source: String? = current["source_event_id"]
                guard (current["permissions"] as Data) == effect.encodedPermissions,
                      source == effect.sourceEventID.rawValue && (current["canonical_digest"] as Data?) == effect.digest,
                      currentSequence == sequence
                else { throw V2ClientProjectionError.invalidMessagePayload }
            }
        }
        try db.execute(sql: """
            INSERT INTO \(policies) (room_id, role, permissions, revision, room_sequence, source_event_id, canonical_digest)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id, role) DO UPDATE SET permissions = excluded.permissions, revision = excluded.revision,
                room_sequence = excluded.room_sequence, source_event_id = excluded.source_event_id, canonical_digest = excluded.canonical_digest
            """, arguments: [effect.roomID.rawValue, effect.role.rawValue, effect.encodedPermissions, effect.revision, sequence, effect.sourceEventID.rawValue, effect.digest])
        try db.execute(sql: "INSERT INTO \(revisions) (room_id, revision) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET revision = MAX(\(revisions).revision, excluded.revision)", arguments: [effect.roomID.rawValue, effect.revision])
    }


    private static func applyMemberEffect(_ effect: V2LocalMemberEffect, target: ProjectionTableTarget, db: Database) throws {
        let effects = target.table("v2_member_effects")
        let roles = target.table("v2_group_member_roles")
        if let prior = try Row.fetchOne(db, sql: "SELECT * FROM \(effects) WHERE source_event_id = ? OR (room_id = ? AND user_id = ? AND membership_revision = ?)",
            arguments: [effect.source, effect.room, effect.user, effect.revision]) {
            let priorSequence = try optionalEffectInteger(prior, "room_sequence")
            _ = try effectInteger(prior, "projection_sequence")
            guard try effectInteger(prior, "membership_revision") == effect.revision,
                  (prior["source_event_id"] as String) == effect.source,
                  (prior["canonical_digest"] as Data) == effect.digest,
                  priorSequence == nil || effect.roomSequence == nil || priorSequence == effect.roomSequence
            else { throw V2ClientProjectionError.invalidMessagePayload }
            try db.execute(sql: "UPDATE \(effects) SET room_sequence = COALESCE(room_sequence, ?) WHERE source_event_id = ?", arguments: [effect.roomSequence, effect.source])
        } else {
            try db.execute(sql: "INSERT INTO \(effects) (source_event_id, room_id, user_id, membership_revision, action, role, room_sequence, projection_sequence, canonical_digest) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [effect.source, effect.room, effect.user, effect.revision, effect.action, effect.role, effect.roomSequence, effect.projectionSequence, effect.digest])
        }
        // Keep old source identities for conflict detection, but only the newest
        // member revision can change the visible role (including its absence).
        // Validate every revision before reducing: MAX alone can hide a smaller REAL.
        guard let history = try Row.fetchOne(db, sql: """
            SELECT CASE WHEN MIN(CASE WHEN typeof(membership_revision) = 'integer'
                AND membership_revision > 0 THEN 1 ELSE 0 END) = 1
                THEN MAX(membership_revision) ELSE NULL END AS latest
            FROM \(effects) WHERE room_id = ? AND user_id = ?
            """, arguments: [effect.room, effect.user]) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        guard try effectInteger(history, "latest") == effect.revision else { return }
        if let role = effect.role {
            guard let stored = try Row.fetchOne(db, sql: "SELECT room_sequence, projection_sequence FROM \(effects) WHERE source_event_id = ?", arguments: [effect.source]) else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            let projectionSequence = try effectInteger(stored, "projection_sequence")
            let storedSequence = try optionalEffectInteger(stored, "room_sequence") ?? projectionSequence
            try db.execute(sql: "INSERT INTO \(roles) (room_id, user_id, role, membership_revision, room_sequence) VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id, user_id) DO UPDATE SET role = excluded.role, membership_revision = excluded.membership_revision, room_sequence = excluded.room_sequence",
                arguments: [effect.room, effect.user, role, effect.revision, storedSequence])
        } else {
            try db.execute(sql: "DELETE FROM \(roles) WHERE room_id = ? AND user_id = ?", arguments: [effect.room, effect.user])
        }
    }

    private static func applyGroupCapability(
        _ record: V2ClientSyncRecord,
        target: ProjectionTableTarget = .live,
        expectedRoomSequence: UInt64? = nil,
        expectedRoomID: RoomID? = nil,
        db: Database
    ) throws {
        let header = try V2ClientGroupCapabilityProjection.header(record.payload)
        switch header.eventType {
        case "message.pinned_changed":
            try applyPinnedMessage(V2LocalPinnedMessageEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.announcement_changed":
            try applyAnnouncement(V2LocalAnnouncementEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.avatar_changed":
            try applyGroupAvatarInvalidation(V2LocalGroupAvatarEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.nickname_changed":
            try applyGroupNicknameInvalidation(V2LocalGroupNicknameEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.role_permissions_changed":
            try applyRolePolicy(V2LocalRolePolicyEffect(record: record, expectedRoomSequence: expectedRoomSequence, expectedRoomID: expectedRoomID), target: target, db: db)
        case "group.member_role_changed":
            try applyMemberEffect(V2LocalMemberEffect(record: record, expectedRoomID: expectedRoomID,
                expectedRoomSequence: expectedRoomSequence), target: target, db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func applyRelationship(_ record: V2ClientSyncRecord, target tableTarget: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let targetUserID: String; let state: String; let requestedByUserID: String?; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case state; case requestedByUserID = "requested_by_user_id"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard let state = V2RelationshipState(rawValue: payload.state) else { throw V2ClientSocialProjectionError.invalidPayload }
        let target: UserID; let requester: UserID?
        do { target = try .init(payload.targetUserID); requester = try payload.requestedByUserID.map(UserID.init) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard (state == .pending) == (requester != nil) else { throw V2ClientSocialProjectionError.invalidPayload }
        let table = tableTarget.table("v2_relationship_projections")
        try db.execute(sql: "INSERT INTO \(table) (target_user_id, state, requested_by_user_id, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(target_user_id) DO UPDATE SET state = excluded.state, requested_by_user_id = excluded.requested_by_user_id, updated_at = excluded.updated_at", arguments: [target.rawValue, state.rawValue, requester?.rawValue, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyUserBlock(_ record: V2ClientSyncRecord, target tableTarget: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable { let targetUserID: String; let isBlocked: Bool; let updatedAtMilliseconds: Int64; enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case isBlocked = "is_blocked"; case updatedAtMilliseconds = "updated_at_ms" } }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let target: UserID
        do { target = try .init(payload.targetUserID) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let table = tableTarget.table("v2_user_block_projections")
        try db.execute(sql: "INSERT INTO \(table) (target_user_id, is_blocked, updated_at) VALUES (?, ?, ?) ON CONFLICT(target_user_id) DO UPDATE SET is_blocked = excluded.is_blocked, updated_at = excluded.updated_at", arguments: [target.rawValue, payload.isBlocked, Double(payload.updatedAtMilliseconds) / 1_000])
    }

    private static func applyStrangerMessagePermission(_ record:V2ClientSyncRecord,target:ProjectionTableTarget = .live,db:Database) throws {
        struct Payload:Decodable {let allowsStrangerMessages:Bool;let revision:UInt64;let updatedAtMilliseconds:Int64;enum CodingKeys:String,CodingKey {case allowsStrangerMessages="allows_stranger_messages",revision,updatedAtMilliseconds="updated_at_ms"}}
        let value:Payload
        do {value=try JSONDecoder().decode(Payload.self,from:record.payload)} catch {throw V2ClientSocialProjectionError.invalidPayload}
        try applyVersionedPreference(table:target.table("v2_stranger_message_preference"),values:["allows_stranger_messages":value.allowsStrangerMessages],revision:value.revision,updatedAt:value.updatedAtMilliseconds,db:db)
    }
    private static func applyUserAddPermission(_ record:V2ClientSyncRecord,target:ProjectionTableTarget = .live,db:Database) throws {
        struct Payload:Decodable {let allowsBeingAdded:Bool;let revision:UInt64;let updatedAtMilliseconds:Int64;enum CodingKeys:String,CodingKey {case allowsBeingAdded="allows_being_added",revision,updatedAtMilliseconds="updated_at_ms"}}
        let value:Payload
        do {value=try JSONDecoder().decode(Payload.self,from:record.payload)} catch {throw V2ClientSocialProjectionError.invalidPayload}
        try applyVersionedPreference(table:target.table("v2_user_add_preference"),values:["allows_being_added":value.allowsBeingAdded],revision:value.revision,updatedAt:value.updatedAtMilliseconds,db:db)
    }
    private static func applyLiveActivityPreference(_ record:V2ClientSyncRecord,target:ProjectionTableTarget = .live,db:Database) throws {
        struct Payload:Decodable {let online:Bool;let typing:Bool;let revision:UInt64;let updatedAtMilliseconds:Int64;enum CodingKeys:String,CodingKey {case online="allows_online_presence",typing="allows_typing_indicators",revision,updatedAtMilliseconds="updated_at_ms"}}
        let value:Payload
        do {value=try JSONDecoder().decode(Payload.self,from:record.payload)} catch {throw V2ClientSocialProjectionError.invalidPayload}
        try applyVersionedPreference(table:target.table("v2_live_activity_preference"),values:["allows_online_presence":value.online,"allows_typing_indicators":value.typing],revision:value.revision,updatedAt:value.updatedAtMilliseconds,db:db)
    }
    // Only schema-owned table/column names reach this helper; payloads carry values.
    private static func applyVersionedPreference(table:String,values:[String:Bool],revision:UInt64,updatedAt:Int64,db:Database) throws {
        guard revision>0,revision<=UInt64(Int64.max),updatedAt>=0 else {throw V2ClientSocialProjectionError.invalidPayload}
        let columns=values.keys.sorted(),time=Double(updatedAt)/1000
        if let prior=try Row.fetchOne(db,sql:"SELECT * FROM \(table) WHERE singleton=1") {
            let old=try storageUnsigned(prior,column:"revision")
            guard old>0 else {throw V2ClientSyncError.storageRangeExceeded}
            if revision<old {return}
            if revision==old {
                guard columns.allSatisfy({(prior[$0] as Bool)==values[$0]}),(prior["updated_at"] as Double)==time else {throw V2ClientSocialProjectionError.invalidPayload};return
            }
        }
        let names=columns.joined(separator:","),marks=columns.map {_ in "?"}.joined(separator:","),updates=columns.map {"\($0)=excluded.\($0)"}.joined(separator:",")
        var arguments=StatementArguments(columns.map {values[$0]!});arguments += [Int64(revision),time]
        try db.execute(sql:"INSERT INTO \(table)(singleton,\(names),revision,updated_at) VALUES(1,\(marks),?,?) ON CONFLICT(singleton) DO UPDATE SET \(updates),revision=excluded.revision,updated_at=excluded.updated_at",arguments:arguments)
        if ["v2_stranger_message_preference","v2_user_add_preference","v2_live_activity_preference"].contains(table) {try persistAccountPreferenceFloors(db:db)}
    }

    private static func applyDirectReadReceipt(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable {
            let roomID: String
            let readerUserID: String
            let readThroughRoomSequence: UInt64
            let recordedAtMilliseconds: Int64
            let isVisible: Bool
            let readerPreferenceRevision: UInt64
            let viewerPreferenceRevision: UInt64
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id", readerUserID = "reader_user_id"
                case readThroughRoomSequence = "read_through_room_sequence"
                case recordedAtMilliseconds = "recorded_at_ms", isVisible = "is_visible"
                case readerPreferenceRevision = "reader_preference_revision"
                case viewerPreferenceRevision = "viewer_preference_revision"
            }
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: record.payload) }
        catch { throw V2ClientSocialProjectionError.invalidPayload }
        let roomID: RoomID; let readerID: UserID
        do { roomID = try .init(payload.roomID); readerID = try .init(payload.readerUserID) }
        catch { throw V2ClientSocialProjectionError.invalidPayload }
        guard (payload.isVisible || payload.readThroughRoomSequence == 0),
              payload.readThroughRoomSequence <= UInt64(Int64.max),
              payload.readerPreferenceRevision <= UInt64(Int64.max),
              payload.viewerPreferenceRevision <= UInt64(Int64.max)
        else { throw V2ClientSocialProjectionError.invalidPayload }
        let table = target.table("v2_direct_read_receipt_projections")
        if let prior = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE room_id = ?", arguments: [roomID.rawValue]) {
            guard (prior["reader_user_id"] as String) == readerID.rawValue else { throw V2ClientSocialProjectionError.invalidPayload }
            let priorSequence = try storageUnsigned(prior, column: "read_through_room_sequence")
            let readerVersion = try storageUnsigned(prior, column: "reader_preference_revision")
            let viewerVersion = try storageUnsigned(prior, column: "viewer_preference_revision")
            let older = payload.readerPreferenceRevision < readerVersion || payload.viewerPreferenceRevision < viewerVersion
            let newer = payload.readerPreferenceRevision > readerVersion || payload.viewerPreferenceRevision > viewerVersion
            // A coherent control-plane snapshot cannot move one preference
            // forward and the other backward for the same reader/viewer pair.
            if older && newer { throw V2ClientSocialProjectionError.invalidPayload }
            if older { return }
            if !newer {
                guard (prior["is_visible"] as Bool) == payload.isVisible else { throw V2ClientSocialProjectionError.invalidPayload }
                if !payload.isVisible { return }
                if payload.readThroughRoomSequence < priorSequence { return }
                if payload.readThroughRoomSequence == priorSequence,
                   Double(payload.recordedAtMilliseconds) / 1_000 <= (prior["recorded_at"] as Double) { return }
            }
        }
        // Visible zero is a policy-only state, not evidence of reading. Public
        // queries require positive progress, and same-policy receipts may advance it.
        // Keep hidden versions in both live and snapshot tables; deleting
        // them would let a delayed visible event resurrect revoked disclosure.
        try db.execute(sql: """
            INSERT INTO \(table) (room_id, reader_user_id, read_through_room_sequence, recorded_at,
                is_visible, reader_preference_revision, viewer_preference_revision)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET reader_user_id = excluded.reader_user_id,
                read_through_room_sequence = excluded.read_through_room_sequence,
                recorded_at = excluded.recorded_at, is_visible = excluded.is_visible,
                reader_preference_revision = excluded.reader_preference_revision,
                viewer_preference_revision = excluded.viewer_preference_revision
            """, arguments: [roomID.rawValue, readerID.rawValue,
                payload.isVisible ? Int64(payload.readThroughRoomSequence) : 0,
                Double(payload.recordedAtMilliseconds) / 1_000, payload.isVisible,
                Int64(payload.readerPreferenceRevision), Int64(payload.viewerPreferenceRevision)])
    }

    /// 应用读者自己的已读水位投影。
    ///
    /// 该投影来自本账号的其他设备，表示“我已经读到这个房间的这个序号”。它不携带内容，
    /// 也不改变消息投影；唯一效果是把本地的已读水位单调推进，使未读计数无需等待服务端
    /// 摘要刷新即可归零。乱序或重复投影不得让水位回退。
    private static func applyOwnReadWatermark(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable {
            let roomID: String
            let readThroughRoomSequence: UInt64
            let recordedAtMilliseconds: Int64
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case readThroughRoomSequence = "read_through_room_sequence"
                case recordedAtMilliseconds = "recorded_at_ms"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: record.payload),
              payload.readThroughRoomSequence > 0,
              payload.readThroughRoomSequence <= UInt64(Int64.max)
        else { throw V2ClientSocialProjectionError.invalidPayload }
        let roomID: RoomID
        do { roomID = try .init(payload.roomID) } catch { throw V2ClientSocialProjectionError.invalidPayload }
        let table = target.table("v2_room_read_watermarks")
        if let prior = try Row.fetchOne(db, sql: "SELECT read_through_room_sequence FROM \(table) WHERE room_id = ?", arguments: [roomID.rawValue]) {
            let sequence = try storageInteger(prior, column: "read_through_room_sequence")
            guard sequence > 0 else { throw V2ClientSyncError.storageRangeExceeded }
        }
        try db.execute(sql: """
            INSERT INTO \(table) (room_id, read_through_room_sequence, recorded_at)
            VALUES (?, ?, ?)
            ON CONFLICT(room_id) DO UPDATE SET
                read_through_room_sequence = MAX(\(table).read_through_room_sequence, excluded.read_through_room_sequence),
                recorded_at = CASE
                    WHEN excluded.read_through_room_sequence >= \(table).read_through_room_sequence
                    THEN excluded.recorded_at
                    ELSE \(table).recorded_at
                END
            """, arguments: [
                roomID.rawValue,
                try Self.storageInteger(payload.readThroughRoomSequence),
                Double(payload.recordedAtMilliseconds) / 1_000
            ])
    }

    private static func applyReadReceiptPreference(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, db: Database) throws {
        struct Payload: Decodable {
            let allowsDirect: Bool
            let allowsGroup: Bool
            let updatedAt: Int64
            let revision: UInt64
            enum CodingKeys: String, CodingKey {
                case allowsDirect = "allows_direct_read_receipts", allowsGroup = "allows_group_read_receipts"
                case updatedAt = "updated_at_ms", revision = "preference_revision"
            }
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: record.payload),
              payload.updatedAt >= 0, payload.revision > 0, payload.revision <= UInt64(Int64.max) else {
            throw V2ClientSocialProjectionError.invalidPayload
        }
        let table = target.table("v2_read_receipt_preference")
        if let prior = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE singleton = 1") {
            let revision = try storageUnsigned(prior, column: "preference_revision")
            guard revision > 0 else { throw V2ClientSyncError.storageRangeExceeded }
            if payload.revision < revision { return }
            if payload.revision == revision {
                guard (prior["allows_direct_read_receipts"] as Bool) == payload.allowsDirect,
                      (prior["allows_group_read_receipts"] as Bool) == payload.allowsGroup,
                      (prior["updated_at"] as Double) == Double(payload.updatedAt) / 1_000 else {
                    throw V2ClientSocialProjectionError.invalidPayload
                }
                return
            }
        }
        try db.execute(sql: """
            INSERT INTO \(table) (singleton, allows_direct_read_receipts, allows_group_read_receipts, updated_at, preference_revision)
            VALUES (1, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET allows_direct_read_receipts = excluded.allows_direct_read_receipts,
                allows_group_read_receipts = excluded.allows_group_read_receipts,
                updated_at = excluded.updated_at, preference_revision = excluded.preference_revision
            """, arguments: [payload.allowsDirect, payload.allowsGroup, Double(payload.updatedAt) / 1_000, Int64(payload.revision)])
        if case .live = target {try persistAccountPreferenceFloors(db:db)}
    }
    private static func persist(_ projection: V2ClientConversationState, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_conversation_states")
        if let prior = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE room_id=?", arguments: [projection.roomID.rawValue]) {
            let previous: Int64 = prior["revision"]
            if previous > projection.revision.signedValue { return }
            if previous == projection.revision.signedValue {
                guard (prior["is_pinned"] as Bool) == projection.isPinned, (prior["is_archived"] as Bool) == projection.isArchived, (prior["mute_until"] as Double) == (projection.muteUntil?.timeIntervalSince1970 ?? 0), (prior["updated_at"] as Double) == projection.updatedAt.timeIntervalSince1970 else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, is_pinned, is_archived, mute_until, updated_at, revision) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET is_pinned = excluded.is_pinned, is_archived = excluded.is_archived, mute_until = excluded.mute_until, updated_at = excluded.updated_at, revision=excluded.revision", arguments: [projection.roomID.rawValue, projection.isPinned, projection.isArchived, projection.muteUntil?.timeIntervalSince1970 ?? 0, projection.updatedAt.timeIntervalSince1970, projection.revision.signedValue])
    }
    private static func persist(_ projection: V2ClientMessageFavorite, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_message_favorites")
        if let prior = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE message_id=?", arguments: [projection.messageID.rawValue]) {
            let previous: Int64 = prior["revision"]
            if previous > projection.revision.signedValue { return }
            if previous == projection.revision.signedValue {
                guard (prior["room_id"] as String) == projection.roomID.rawValue, (prior["is_favorited"] as Bool) == projection.isFavorited, (prior["updated_at"] as Double) == projection.updatedAt.timeIntervalSince1970 else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: "INSERT INTO \(table) (message_id, room_id, is_favorited, updated_at, revision) VALUES (?, ?, ?, ?, ?) ON CONFLICT(message_id) DO UPDATE SET room_id = excluded.room_id, is_favorited = excluded.is_favorited, updated_at = excluded.updated_at, revision=excluded.revision", arguments: [projection.messageID.rawValue, projection.roomID.rawValue, projection.isFavorited, projection.updatedAt.timeIntervalSince1970, projection.revision.signedValue])
    }

    private static func applyModeration(_ record: V2ClientSyncRecord, expectedRoomID: RoomID, db: Database) throws {
        struct Header: Decodable { let eventType: String; enum CodingKeys: String, CodingKey { case eventType = "event_type" } }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: record.payload) }
        catch { throw V2ClientProjectionError.invalidMessagePayload }
        switch header.eventType {
        case "member.muted":
            let projection = try V2ClientModerationProjection(record: record)
            guard projection.roomID == expectedRoomID, projection.roomSequence == record.sequence else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            try persist(projection, db: db)
        case "room.frozen", "room.unfrozen":
            let projection = try V2ClientRoomControlProjection(record: record)
            guard projection.roomID == expectedRoomID, projection.roomSequence == record.sequence else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            try persist(projection, db: db)
        default: throw V2ClientProjectionError.invalidMessagePayload
        }
    }

    private static func persist(
        _ projection: V2ClientMessageProjection,
        updateConversationSummary: Bool = true,
        enqueueSearchIndex: Bool = true,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        if case .live = target {
            // Validation below shares this transaction: invalid projections roll
            // back the marker as well as the projection. Cache trimming later
            // cannot resurrect a previously materialized local send row.
            try db.execute(sql: "UPDATE v2_message_send_operations SET accepted_projection_observed=1,projection_observed_snapshot_id=NULL WHERE accepted_message_id=? AND room_id=? AND accepted_room_sequence=? AND accepted_projection_observed=0",
                arguments: [projection.messageID.rawValue,projection.roomID.rawValue,try storageInteger(projection.roomSequence)])
        }
        let messages = target.table("v2_message_projections")
        let tombstones = target.table("v2_message_tombstones")
        if let existing = try Row.fetchOne(db, sql: "SELECT * FROM \(messages) WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let decoded = try decodeMessageProjection(existing)
            if projection.messageRevision < decoded.messageRevision {
                guard decoded.hasSameAcceptance(as: projection) else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            guard decoded.sourceEventID == projection.sourceEventID, decoded.messageID == projection.messageID,
                  decoded.roomID == projection.roomID, decoded.roomSequence == projection.roomSequence, decoded.timelineSequence == projection.timelineSequence,
                  decoded.messageRevision == projection.messageRevision, decoded.senderUserID == projection.senderUserID,
                  decoded.text == projection.text, decoded.media == projection.media, decoded.mediaPresentations == projection.mediaPresentations,
                  decoded.mentions == projection.mentions, decoded.entities == projection.entities, decoded.replyTo == projection.replyTo, decoded.forwardedFrom == projection.forwardedFrom, decoded.createdAt == projection.createdAt,
                  decoded.isWithdrawn == projection.isWithdrawn
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(
            sql: """
            INSERT INTO \(messages)
                (message_id, source_event_id, room_id, room_sequence, timeline_sequence, message_revision, sender_user_id, text_body, media_ids, media_presentations, mention_targets, entities, reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id, server_created_at, is_withdrawn)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [projection.messageID.rawValue, projection.sourceEventID.rawValue, projection.roomID.rawValue,
                        try storageInteger(projection.roomSequence), try storageInteger(projection.timelineSequence), try storageInteger(projection.messageRevision), projection.senderUserID.rawValue, projection.text, try encodeMedia(projection.media), try encodeMediaPresentations(projection.mediaPresentations), try encodeMentions(projection.mentions), try encodeEntities(projection.entities, text: projection.text), projection.replyTo?.messageID.rawValue, projection.forwardedFrom?.messageID.rawValue, projection.forwardedFrom?.senderUserID.rawValue,
                        projection.createdAt.timeIntervalSince1970, projection.isWithdrawn]
        )
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM \(tombstones) WHERE message_id = ?", arguments: [projection.messageID.rawValue]) {
            let roomID: String = tombstone["room_id"]
            let revision = try storageInteger(tombstone, column: "message_revision")
            guard roomID == projection.roomID.rawValue, revision > (try storageInteger(projection.messageRevision)) else { throw V2ClientProjectionError.invalidMessagePayload }
            try redactLocalMessageProjection(messageID: projection.messageID, revision: revision, target: target, db: db)
        }
        if case .live = target { try indexMessageResources(projection, db: db) }
        else if !projection.media.isEmpty {
            try db.execute(sql: "INSERT OR REPLACE INTO \(target.table("v2_resource_projection_index_jobs"))(message_id,room_id,queued_revision) VALUES(?,?,?)",
                arguments: [projection.messageID.rawValue,projection.roomID.rawValue,try storageInteger(projection.messageRevision)])
        }
        if updateConversationSummary {
            try upsertConversationSummary(for: projection, db: db)
        }
        if enqueueSearchIndex {
            try enqueueMessageSearchIndexJob(messageID: projection.messageID, db: db)
        }
    }

    private static func upsertConversationSummary(
        for projection: V2ClientMessageProjection,
        db: Database
    ) throws {
        try refreshEffectiveConversationSummary(roomID: projection.roomID, db: db)
    }

    private static func refreshEffectiveConversationSummary(roomID: RoomID, db: Database) throws {
        let candidate = try String.fetchOne(db, sql: """
            SELECT message_id FROM v2_message_projections
            WHERE room_id = ? AND is_withdrawn = 0
            ORDER BY room_sequence DESC, message_id DESC LIMIT 1
            """, arguments: [roomID.rawValue])
        if let candidate {
            try db.execute(sql: """
                INSERT INTO v2_conversation_summaries (room_id, message_id) VALUES (?, ?)
                ON CONFLICT(room_id) DO UPDATE SET message_id = excluded.message_id
                WHERE message_id <> excluded.message_id
                """, arguments: [roomID.rawValue, candidate])
        } else {
            try db.execute(sql: "DELETE FROM v2_conversation_summaries WHERE room_id = ?", arguments: [roomID.rawValue])
        }
    }

    private static func rebuildConversationSummaries(
        messages: String = "v2_message_projections",
        summaries: String = "v2_conversation_summaries",
        db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO \(summaries) (room_id, message_id)
            SELECT room_id, message_id
            FROM (
                SELECT room_id, message_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY room_id
                           ORDER BY room_sequence DESC, message_id DESC
                       ) AS room_rank
                FROM \(messages)
                WHERE is_withdrawn = 0
            )
            WHERE room_rank = 1
            """)
    }

    private static func persist(_ projection: V2ClientTimelineActivityProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let timelineSequence = try storageInteger(projection.timelineSequence)
        let table = target.table("v2_timeline_activity_projections")
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, timeline_sequence, event_type, server_created_at FROM \(table) WHERE source_event_id = ?", arguments: [projection.sourceEventID.rawValue]) {
            guard (row["room_id"] as String) == projection.roomID.rawValue,
                  (try storageInteger(row, column: "timeline_sequence")) == timelineSequence,
                  (row["event_type"] as String) == projection.kind.rawValue,
                  (row["server_created_at"] as Double) == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (source_event_id, room_id, timeline_sequence, event_type, server_created_at) VALUES (?, ?, ?, ?, ?)", arguments: [projection.sourceEventID.rawValue, projection.roomID.rawValue, timelineSequence, projection.kind.rawValue, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientDirectSendingCapability, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_direct_sending_capabilities")
        let version = try storageInteger(projection.stateVersion)
        guard version > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        if let row = try Row.fetchOne(db, sql: "SELECT can_send, state_version, updated_at FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let existingVersion = try storageInteger(row, column: "state_version")
            guard existingVersion > 0 else { throw V2ClientSyncError.storageRangeExceeded }
            if existingVersion > version { return }
            if existingVersion == version {
                guard (row["can_send"] as Bool) == projection.canSend,
                      (row["updated_at"] as Double) == projection.updatedAt.timeIntervalSince1970
                else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, can_send, state_version, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET can_send = excluded.can_send, state_version = excluded.state_version, updated_at = excluded.updated_at", arguments: [projection.roomID.rawValue, projection.canSend, version, projection.updatedAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientModerationProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_moderation_projections")
        if let existing = try Row.fetchOne(db, sql: "SELECT room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at FROM \(table) WHERE source_event_id = ?", arguments: [projection.sourceEventID.rawValue]) {
            let roomID: String = existing["room_id"]
            let sequence = try storageInteger(existing, column: "room_sequence")
            let actorUserID: String = existing["actor_user_id"]
            let targetUserID: String = existing["target_user_id"]
            let muteUntil: Double = existing["mute_until"]
            let createdAt: Double = existing["server_created_at"]
            guard roomID == projection.roomID.rawValue, sequence == (try storageInteger(projection.roomSequence)),
                  actorUserID == projection.actorUserID.rawValue, targetUserID == projection.targetUserID.rawValue,
                  muteUntil == projection.muteUntil.timeIntervalSince1970, createdAt == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (source_event_id, room_id, room_sequence, actor_user_id, target_user_id, mute_until, server_created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [projection.sourceEventID.rawValue, projection.roomID.rawValue, try storageInteger(projection.roomSequence), projection.actorUserID.rawValue, projection.targetUserID.rawValue, projection.muteUntil.timeIntervalSince1970, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientRoomControlProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_room_control_projections")
        if let existing = try Row.fetchOne(db, sql: "SELECT room_sequence FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let sequence = try storageInteger(existing, column: "room_sequence")
            let projectionSequence = try storageInteger(projection.roomSequence)
            guard sequence < projectionSequence else {
                if sequence == projectionSequence { return }
                throw V2ClientProjectionError.invalidMessagePayload
            }
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, source_event_id, room_sequence, actor_user_id, is_frozen, server_created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(room_id) DO UPDATE SET source_event_id = excluded.source_event_id, room_sequence = excluded.room_sequence, actor_user_id = excluded.actor_user_id, is_frozen = excluded.is_frozen, server_created_at = excluded.server_created_at", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, try storageInteger(projection.roomSequence), projection.actorUserID.rawValue, projection.isFrozen, projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientRoomProfileProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_room_profile_projections")
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, title, owner_user_id, capacity_class, membership_revision, created_at FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let sourceEventID: String = existing["source_event_id"]; let title: String = existing["title"]
            let ownerUserID: String = existing["owner_user_id"]; let capacityClass: String = existing["capacity_class"]
            let membershipRevision = try storageInteger(existing, column: "membership_revision"); let createdAt: Double = existing["created_at"]
            let incomingRevision = try storageInteger(projection.membershipRevision)
            guard title == projection.title, ownerUserID == projection.ownerUserID.rawValue,
                  capacityClass == projection.capacityClass.rawValue,
                  createdAt == projection.createdAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if membershipRevision > incomingRevision { return }
            if membershipRevision == incomingRevision {
                guard sourceEventID == projection.sourceEventID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
            }
            try db.execute(
                sql: """
                    UPDATE \(table)
                    SET source_event_id = ?,
                        membership_revision = ?,
                        is_group_event_authorized = 1
                    WHERE room_id = ?
                    """,
                arguments: [projection.sourceEventID.rawValue, incomingRevision, projection.roomID.rawValue]
            )
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, source_event_id, title, owner_user_id, capacity_class, membership_revision, is_group_event_authorized, created_at) VALUES (?, ?, ?, ?, ?, ?, 1, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.title, projection.ownerUserID.rawValue, projection.capacityClass.rawValue, try storageInteger(projection.membershipRevision), projection.createdAt.timeIntervalSince1970])
    }

    private static func persist(_ projection: V2ClientDirectRoomProfileProjection, target: ProjectionTableTarget = .live, db: Database) throws {
        let table = target.table("v2_direct_room_profile_projections")
        if let floor = try profileSecurityFloor(userID: projection.publicIdentity.userID, target: target, db: db),
           projection.revision <= UInt64(floor.revision) { return }
        if let created = try Double.fetchOne(db, sql: "SELECT room_created_at FROM v2_direct_room_identities WHERE room_id = ?", arguments: [projection.roomID.rawValue]),
           created != projection.roomCreatedAt.timeIntervalSince1970 { throw V2ClientProjectionError.invalidMessagePayload }
        func grantRoomEventAccessIfLive() throws {
            guard case .live = target else { return }
            try db.execute(
                sql: "INSERT INTO v2_room_event_authorizations (room_id, is_authorized) VALUES (?, 1) ON CONFLICT(room_id) DO UPDATE SET is_authorized = excluded.is_authorized",
                arguments: [projection.roomID.rawValue]
            )
        }
        if let existing = try Row.fetchOne(db, sql: "SELECT source_event_id, target_user_id, public_handle, display_name, account_kind, revision, updated_at, room_created_at FROM \(table) WHERE room_id = ?", arguments: [projection.roomID.rawValue]) {
            let existingRevision = try storageInteger(existing, column: "revision")
            let incomingRevision = try storageInteger(projection.revision)
            guard (existing["target_user_id"] as String) == projection.publicIdentity.userID.rawValue,
                  (existing["room_created_at"] as Double) == projection.roomCreatedAt.timeIntervalSince1970
            else { throw V2ClientProjectionError.invalidMessagePayload }
            if existingRevision > incomingRevision { return }
            if existingRevision == incomingRevision {
                guard (existing["updated_at"] as Double) == projection.updatedAt.timeIntervalSince1970,
                      (existing["public_handle"] as String) == projection.publicIdentity.handle.rawValue,
                      (existing["display_name"] as String) == projection.publicIdentity.displayName,
                      (existing["account_kind"] as String) == projection.publicIdentity.accountKind.rawValue
                else { throw V2ClientProjectionError.invalidMessagePayload }
                try persistDirectProfileCache(projection, target: target, db: db)
                return
            }
            try db.execute(sql: "UPDATE \(table) SET source_event_id = ?, target_user_id = ?, public_handle = ?, display_name = ?, account_kind = ?, revision = ?, updated_at = ? WHERE room_id = ?", arguments: [projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, projection.publicIdentity.accountKind.rawValue, incomingRevision, projection.updatedAt.timeIntervalSince1970, projection.roomID.rawValue])
            try persistDirectProfileCache(projection, target: target, db: db)
            try grantRoomEventAccessIfLive()
            return
        }
        try db.execute(sql: "INSERT INTO \(table) (room_id, source_event_id, target_user_id, public_handle, display_name, account_kind, revision, updated_at, room_created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", arguments: [projection.roomID.rawValue, projection.sourceEventID.rawValue, projection.publicIdentity.userID.rawValue, projection.publicIdentity.handle.rawValue, projection.publicIdentity.displayName, projection.publicIdentity.accountKind.rawValue, try storageInteger(projection.revision), projection.updatedAt.timeIntervalSince1970, projection.roomCreatedAt.timeIntervalSince1970])
        try persistDirectProfileCache(projection, target: target, db: db)
        try grantRoomEventAccessIfLive()
    }

    /// A room discovery carries only public identity, not an authoritative
    /// hydrated avatar or visibility state. Preserve a newer or equally
    /// current hydrated view when asynchronous discovery arrives afterward.
    private static func persistDirectProfileCache(_ projection: V2ClientDirectRoomProfileProjection, target: ProjectionTableTarget, db: Database) throws {
        let table = target.table("v2_profile_views")
        let revision = try storageInteger(projection.revision)
        if let existing = try Row.fetchOne(db, sql: "SELECT revision, visibility_revision, state, public_handle, display_name, account_kind FROM \(table) WHERE user_id = ?", arguments: [projection.publicIdentity.userID.rawValue]) {
            let priorRevision = try storageInteger(existing, column: "revision")
            let visibilityRevision = try storageInteger(existing, column: "visibility_revision")
            if priorRevision > revision || visibilityRevision > revision { return }
            if priorRevision == revision {
                if (existing["state"] as String) == "active" {
                    guard (existing["public_handle"] as String?) == projection.publicIdentity.handle.rawValue,
                          (existing["display_name"] as String?) == projection.publicIdentity.displayName,
                          (existing["account_kind"] as String?) == projection.publicIdentity.accountKind.rawValue
                    else { throw V2ClientProjectionError.invalidMessagePayload }
                }
                return
            }
        }
        try persist(profileView(from: projection), target: target, db: db)
    }

    private static func profileView(from projection: V2ClientDirectRoomProfileProjection) throws -> V2ProfileView {
        guard let revision = V2ProfileRevision(rawValue: projection.revision) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            userID: projection.publicIdentity.userID,
            publicIdentity: projection.publicIdentity,
            avatar: nil,
            state: .active,
            revision: revision,
            visibilityRevision: revision
        )
    }

    private static func persist(_ profile: V2ProfileView, target: ProjectionTableTarget = .live, db: Database) throws {
        guard try profileSurvivesSecurityFloor(profile, target: target, db: db) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let incomingRevision = try storageInteger(profile.revision.rawValue)
        let incomingVisibilityRevision = try storageInteger(profile.visibilityRevision.rawValue)
        let table = target.table("v2_profile_views")
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision FROM \(table) WHERE user_id = ?",
            arguments: [profile.userID.rawValue]
        ) {
            let existingRevision = try storageInteger(existing, column: "revision")
            let existingVisibilityRevision = try storageInteger(existing, column: "visibility_revision")
            guard existingRevision <= incomingRevision, existingVisibilityRevision <= incomingVisibilityRevision else {
                throw V2ClientProjectionError.invalidMessagePayload
            }
            if existingRevision == incomingRevision, existingVisibilityRevision == incomingVisibilityRevision {
                guard (existing["public_handle"] as String?) == profile.publicIdentity?.handle.rawValue,
                      (existing["display_name"] as String?) == profile.publicIdentity?.displayName,
                      (existing["account_kind"] as String?) == profile.publicIdentity?.accountKind.rawValue,
                      (existing["avatar_media_id"] as String?) == profile.avatar?.mediaID.rawValue,
                      (existing["state"] as String) == profile.state.rawValue
                else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
            try db.execute(
                sql: "UPDATE \(table) SET public_handle = ?, display_name = ?, account_kind = ?, avatar_media_id = ?, state = ?, revision = ?, visibility_revision = ?, updated_at = ? WHERE user_id = ?",
                arguments: [profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.publicIdentity?.accountKind.rawValue, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970, profile.userID.rawValue]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO \(table) (user_id, public_handle, display_name, account_kind, avatar_media_id, state, revision, visibility_revision, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [profile.userID.rawValue, profile.publicIdentity?.handle.rawValue, profile.publicIdentity?.displayName, profile.publicIdentity?.accountKind.rawValue, profile.avatar?.mediaID.rawValue, profile.state.rawValue, incomingRevision, incomingVisibilityRevision, Date().timeIntervalSince1970]
            )
        }
    }

    private static func persist(_ invalidation: V2ClientProfileInvalidation, target: ProjectionTableTarget = .live, db: Database) throws {
        let revision = try storageInteger(invalidation.minimumRevision.rawValue)
        let profileViews = target.table("v2_profile_views")
        let invalidations = target.table("v2_profile_invalidations")
        let directProfiles = target.table("v2_direct_room_profile_projections")
        try validateProfileInvalidation(userID: invalidation.userID, table: invalidations, db: db)
        var newestRevision: Int64 = 0
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT revision FROM \(profileViews) WHERE user_id = ?",
            arguments: [invalidation.userID.rawValue]
        ) {
            newestRevision = try storageInteger(existing, column: "revision")
        }
        for row in try Row.fetchAll(db, sql: "SELECT revision FROM \(directProfiles) WHERE target_user_id = ?",
                                   arguments: [invalidation.userID.rawValue]) {
            _ = try storageInteger(row, column: "revision")
        }
        // Keep the monotonic floor even when a newer authorized fact already
        // exists. Clearing a display/cache must not reopen older HTTP replies.
        try db.execute(
            sql: """
            INSERT INTO \(invalidations) (user_id, minimum_revision, profile_state, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                minimum_revision = MAX(\(invalidations).minimum_revision, excluded.minimum_revision),
                profile_state = CASE
                    WHEN excluded.minimum_revision >= \(invalidations).minimum_revision
                    THEN excluded.profile_state
                    ELSE \(invalidations).profile_state
                END,
                updated_at = excluded.updated_at
            WHERE excluded.minimum_revision > \(invalidations).minimum_revision
            """,
            arguments: [invalidation.userID.rawValue, revision, invalidation.state.rawValue, Date().timeIntervalSince1970]
        )
        let floor = try profileSecurityFloor(userID: invalidation.userID, target: target, db: db)!
        try db.execute(sql: "DELETE FROM \(directProfiles) WHERE target_user_id = ? AND revision <= ?",
                       arguments: [invalidation.userID.rawValue, floor.revision])
        try db.execute(sql: "DELETE FROM \(profileViews) WHERE user_id = ? AND state = 'active' AND revision <= ?",
                       arguments: [invalidation.userID.rawValue, floor.revision])
        if case .live = target, newestRevision <= floor.revision {
            try db.execute(sql: """
                DELETE FROM v2_direct_room_identities WHERE target_user_id = ?
                AND NOT EXISTS (SELECT 1 FROM v2_local_profile_display
                    WHERE user_id = ? AND profile_revision > ?)
                """, arguments: [invalidation.userID.rawValue, invalidation.userID.rawValue, floor.revision])
        }
    }

    private static func profileSecurityFloor(userID: UserID, target: ProjectionTableTarget = .live, db: Database) throws -> (revision: Int64, state: String)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT minimum_revision,profile_state FROM \(target.table("v2_profile_invalidations")) WHERE user_id = ?",
                                        arguments: [userID.rawValue]) else { return nil }
        let revision = try storageInteger(row, column: "minimum_revision")
        guard revision > 0 else { throw V2ClientSyncError.storageRangeExceeded }
        return (revision, row["profile_state"])
    }

    private static func profileSurvivesSecurityFloor(_ profile: V2ProfileView, target: ProjectionTableTarget = .live, db: Database) throws -> Bool {
        guard let floor = try profileSecurityFloor(userID: profile.userID, target: target, db: db) else { return true }
        return profile.revision.signedValue > floor.revision
            || (profile.revision.signedValue == floor.revision && profile.state.rawValue == floor.state)
    }

    private static func validateProfileInvalidation(userID: UserID, table: String, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT minimum_revision FROM \(table) WHERE user_id = ?", arguments: [userID.rawValue]) {
            let revision = try storageInteger(row, column: "minimum_revision")
            guard revision > 0 else { throw V2ClientSyncError.storageRangeExceeded }
        }
    }

    private static func persist(_ tombstone: V2ClientMessageTombstone, db: Database) throws {
        try db.execute(sql: "UPDATE v2_message_send_operations SET accepted_projection_observed=1,projection_observed_snapshot_id=NULL WHERE accepted_message_id=? AND room_id=? AND accepted_projection_observed=0",
            arguments: [tombstone.messageID.rawValue,tombstone.roomID.rawValue])
        let tombstoneRevision = try storageInteger(tombstone.messageRevision)
        if let existing = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [tombstone.messageID.rawValue]) {
            let roomID: String = existing["room_id"]
            let revision = try storageInteger(existing, column: "message_revision")
            guard roomID == tombstone.roomID.rawValue, revision == tombstoneRevision else { throw V2ClientProjectionError.invalidMessagePayload }
        } else {
            try db.execute(sql: "INSERT INTO v2_message_tombstones (message_id, source_event_id, room_id, message_revision) VALUES (?, ?, ?, ?)", arguments: [tombstone.messageID.rawValue, tombstone.sourceEventID.rawValue, tombstone.roomID.rawValue, try storageInteger(tombstone.messageRevision)])
        }
        try db.execute(
            sql: "DELETE FROM v2_message_reactions WHERE message_id = ?",
            arguments: [tombstone.messageID.rawValue]
        )
        if let projection = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ?", arguments: [tombstone.messageID.rawValue]) {
            let roomID: String = projection["room_id"]
            let revision = try storageInteger(projection, column: "message_revision")
            guard roomID == tombstone.roomID.rawValue, revision <= tombstoneRevision else { throw V2ClientProjectionError.invalidMessagePayload }
            if revision == tombstoneRevision {
                // Snapshot activation may have installed this terminal value
                // without the source-event effect claim. Validate materialized
                // content, then consume the late event without another FTS job.
                let current = try decodeMessageProjection(projection)
                guard current.isWithdrawn, current.text == "[removed]",
                      current.media.isEmpty, current.mediaPresentations.isEmpty,
                      current.mentions.isEmpty, current.entities.isEmpty,
                      current.forwardedFrom == nil
                else { throw V2ClientProjectionError.invalidMessagePayload }
                if current.replyTo != nil {
                    try db.execute(sql: "UPDATE v2_message_projections SET reply_to_message_id = NULL WHERE message_id = ?", arguments: [tombstone.messageID.rawValue])
                }
                return
            }
            try redactLocalMessageProjection(messageID: tombstone.messageID, revision: try storageInteger(tombstone.messageRevision), db: db)
            try enqueueMessageSearchIndexJob(messageID: tombstone.messageID, db: db)
        }
    }

    /// 清除本地消息投影中的正文内容。
    ///
    /// 墓碑是持久化的权限吊销，而不只是一个渲染标记。这里会在全文检索任务运行之前
    /// 先删除承载内容的本地列，使崩溃也不会让正文、媒体引用、富文本实体或提及目标
    /// 通过其他本地功能继续可见。
    ///
    /// - Parameters:
    ///   - messageID: 目标消息。
    ///   - roomID: 目标房间。
    ///   - messageRevision: 目标修订。
    ///   - db: 当前写入事务。
    /// - Throws: 数据库读写失败时抛出。
    private static func redactLocalMessageProjection(
        messageID: MessageID,
        revision: Int64,
        target: ProjectionTableTarget = .live,
        db: Database
    ) throws {
        let messages = target.table("v2_message_projections")
        try db.execute(
            sql: """
            UPDATE \(messages)
            SET message_revision = ?, is_withdrawn = 1, text_body = '[removed]',
                media_ids = '[]', media_presentations = '[]',
                mention_targets = '[]', entities = '[]',
                reply_to_message_id = NULL, forwarded_from_message_id = NULL, forwarded_from_user_id = NULL
            WHERE message_id = ?
            """,
            arguments: [revision, messageID.rawValue]
        )
        if case .live = target,
           let room = try String.fetchOne(db, sql: "SELECT room_id FROM v2_message_projections WHERE message_id = ?", arguments: [messageID.rawValue]) {
            try db.execute(sql: "UPDATE v2_resource_references SET is_revoked=1,business_revision=MAX(business_revision,?) WHERE context_kind='message' AND context_id=?",
                arguments: [revision,messageID.rawValue])
            try refreshEffectiveConversationSummary(roomID: RoomID(room), db: db)
        }
    }

    private static func persistReplacement(_ replacement: V2ClientMessageReplacement, db: Database) throws {
        let value = replacement.projection
        let incoming = try storageInteger(value.messageRevision)
        if let stone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [value.messageID.rawValue]) {
            guard (stone["room_id"] as String) == value.roomID.rawValue, incoming < (try storageInteger(stone, column: "message_revision"))
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id = ?", arguments: [value.messageID.rawValue]) else {
            try persist(value, db: db)
            return
        }
        let current = try decodeMessageProjection(row)
        guard current.hasSameAcceptance(as: value) else { throw V2ClientProjectionError.invalidMessagePayload }
        if current.messageRevision > value.messageRevision { return }
        guard !current.isWithdrawn else { throw V2ClientProjectionError.invalidMessagePayload }
        if current.messageRevision == value.messageRevision {
            guard current == value else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "UPDATE v2_message_projections SET message_revision = ?, text_body = ?, media_ids = ?, media_presentations = ?, mention_targets = ?, entities = ?, reply_to_message_id = ?, forwarded_from_message_id = ?, forwarded_from_user_id = ? WHERE message_id = ?",
            arguments: [incoming, value.text, try encodeMedia(value.media), try encodeMediaPresentations(value.mediaPresentations), try encodeMentions(value.mentions), try encodeEntities(value.entities, text: value.text), value.replyTo?.messageID.rawValue, value.forwardedFrom?.messageID.rawValue, value.forwardedFrom?.senderUserID.rawValue, value.messageID.rawValue])
        try indexMessageResources(value, db: db)
        try enqueueMessageSearchIndexJob(messageID: value.messageID, db: db)
    }

    private static func persist(_ edit: V2ClientMessageEditProjection, db: Database) throws {
        if case .complete(let replacement) = edit.content {
            try persistReplacement(replacement, db: db)
            return
        }
        let incoming = try storageInteger(edit.messageRevision)
        if let tombstone = try Row.fetchOne(db, sql: "SELECT room_id, message_revision FROM v2_message_tombstones WHERE message_id = ?", arguments: [edit.messageID.rawValue]) {
            guard (tombstone["room_id"] as String) == edit.roomID.rawValue,
                  incoming < (try storageInteger(tombstone, column: "message_revision"))
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        guard let row = try Row.fetchOne(db, sql: "SELECT room_id, message_revision, is_withdrawn, text_body, entities FROM v2_message_projections WHERE message_id = ?", arguments: [edit.messageID.rawValue]) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let roomID: String = row["room_id"]
        let revision = try storageInteger(row, column: "message_revision")
        let isWithdrawn: Bool = row["is_withdrawn"]
        guard roomID == edit.roomID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
        // A newer applied revision or an authoritative snapshot already
        // contains this historical effect. Never restore older text.
        if incoming < revision { return }
        guard !isWithdrawn else { throw V2ClientProjectionError.invalidMessagePayload }
        if incoming == revision {
            guard (row["text_body"] as String) == edit.text,
                  (row["entities"] as String) == "[]"
            else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        guard revision < Int64.max, incoming == revision + 1 else { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: "UPDATE v2_message_projections SET text_body = ?, entities = '[]', message_revision = ? WHERE message_id = ?", arguments: [edit.text, incoming, edit.messageID.rawValue])
        if let updated = try Row.fetchOne(db, sql: "SELECT * FROM v2_message_projections WHERE message_id=?", arguments: [edit.messageID.rawValue]) {
            try indexMessageResources(decodeMessageProjection(updated), db: db)
        }
        try enqueueMessageSearchIndexJob(messageID: edit.messageID, db: db)
    }

    private static func applyReaction(_ record: V2ClientSyncRecord, target: ProjectionTableTarget = .live, expectedRoomSequence: UInt64? = nil, db: Database) throws {
        let effect = try V2LocalReactionEffect(record: record)
        if let expectedRoomSequence, UInt64(effect.roomSequence) != expectedRoomSequence { throw V2ClientProjectionError.invalidMessagePayload }
        let reaction = effect.reaction
        let receipts = target.table("v2_reaction_effects"), versions = target.table("v2_reaction_versions")
        let key: StatementArguments = [reaction.messageID.rawValue, reaction.actorUserID.rawValue, reaction.reaction]
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, room_sequence, canonical_digest FROM \(receipts) WHERE source_event_id = ? AND message_id = ? AND actor_user_id = ? AND reaction = ?", arguments: [effect.sourceEventID.rawValue, reaction.messageID.rawValue, reaction.actorUserID.rawValue, reaction.reaction]) {
            guard try effectInteger(row, "room_sequence") == effect.roomSequence,
                  (row["room_id"] as String) == reaction.roomID.rawValue, (row["canonical_digest"] as Data) == effect.digest else { throw V2ClientProjectionError.invalidMessagePayload }
            return
        }
        try db.execute(sql: "INSERT INTO \(receipts) VALUES (?, ?, ?, ?, ?, ?, ?)", arguments: [effect.sourceEventID.rawValue, reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction, effect.roomSequence, effect.digest])
        if let row = try Row.fetchOne(db, sql: "SELECT room_id, room_sequence, source_event_id, canonical_digest FROM \(versions) WHERE message_id = ? AND actor_user_id = ? AND reaction = ?", arguments: key) {
            guard (row["room_id"] as String) == reaction.roomID.rawValue else { throw V2ClientProjectionError.invalidMessagePayload }
            let current = try effectInteger(row, "room_sequence")
            if current > effect.roomSequence { return }
            if current == effect.roomSequence {
                guard (row["source_event_id"] as String) == effect.sourceEventID.rawValue, (row["canonical_digest"] as Data) == effect.digest else { throw V2ClientProjectionError.invalidMessagePayload }
                return
            }
        }
        try db.execute(sql: """
            INSERT INTO \(versions) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id, actor_user_id, reaction) DO UPDATE SET room_sequence = excluded.room_sequence,
                source_event_id = excluded.source_event_id, action = excluded.action, canonical_digest = excluded.canonical_digest
            """, arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction, effect.roomSequence, effect.sourceEventID.rawValue, effect.action.rawValue, effect.digest])
        let withdrawn = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(target.table("v2_message_tombstones")) WHERE message_id = ?) OR EXISTS(SELECT 1 FROM \(target.table("v2_message_projections")) WHERE message_id = ? AND is_withdrawn = 1)", arguments: [reaction.messageID.rawValue, reaction.messageID.rawValue]) == true
        let table = target.table("v2_message_reactions")
        if effect.action == .add && !withdrawn {
            try db.execute(sql: "INSERT INTO \(table) (message_id, room_id, actor_user_id, reaction) VALUES (?, ?, ?, ?) ON CONFLICT(message_id, actor_user_id, reaction) DO NOTHING", arguments: [reaction.messageID.rawValue, reaction.roomID.rawValue, reaction.actorUserID.rawValue, reaction.reaction])
        } else {
            try db.execute(sql: "DELETE FROM \(table) WHERE message_id = ? AND actor_user_id = ? AND reaction = ?", arguments: key)
        }
    }

    private static func preserveReactionStateInSnapshot(authorizedRoomsSQL: String, db: Database) throws {
        let versions = snapshotShadowTable(for: "v2_reaction_versions")
        if try Bool.fetchOne(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL))
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT room_sequence FROM \(versions)
                    UNION ALL SELECT live.room_sequence FROM v2_reaction_versions AS live
                    JOIN authorized AS room ON room.room_id = live.room_id
                ) WHERE typeof(room_sequence) <> 'integer' OR room_sequence <= 0
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        if try Bool.fetchOne(db, sql: """
            WITH authorized AS (\(authorizedRoomsSQL))
            SELECT EXISTS (
                SELECT 1 FROM v2_reaction_versions AS live
                JOIN authorized AS room ON room.room_id = live.room_id
                JOIN \(versions) AS incoming ON incoming.message_id = live.message_id
                    AND incoming.actor_user_id = live.actor_user_id AND incoming.reaction = live.reaction
                WHERE live.room_id <> incoming.room_id
                   OR (live.room_sequence = incoming.room_sequence AND
                       (live.source_event_id <> incoming.source_event_id OR live.canonical_digest <> incoming.canonical_digest OR live.action <> incoming.action))
                   OR (live.source_event_id = incoming.source_event_id AND
                       (live.room_sequence <> incoming.room_sequence OR live.canonical_digest <> incoming.canonical_digest OR live.action <> incoming.action))
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            WITH authorized AS (\(authorizedRoomsSQL))
            INSERT INTO \(versions)
            SELECT live.* FROM v2_reaction_versions AS live JOIN authorized AS room ON room.room_id = live.room_id
            WHERE true
            ON CONFLICT(message_id, actor_user_id, reaction) DO UPDATE SET
                room_sequence = excluded.room_sequence, source_event_id = excluded.source_event_id,
                action = excluded.action, canonical_digest = excluded.canonical_digest
            WHERE excluded.room_sequence > \(versions).room_sequence
            """)
    }

    private static func preserveReactionEffectsInSnapshot(db: Database) throws {
        let versions = snapshotShadowTable(for: "v2_reaction_versions")
        let receipts = snapshotShadowTable(for: "v2_reaction_effects")
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM (
                    SELECT room_sequence FROM \(versions)
                    UNION ALL SELECT room_sequence FROM \(receipts)
                    UNION ALL SELECT effect.room_sequence FROM v2_reaction_effects AS effect
                    JOIN \(versions) AS state ON state.message_id = effect.message_id AND state.room_id = effect.room_id
                        AND state.actor_user_id = effect.actor_user_id AND state.reaction = effect.reaction
                ) WHERE typeof(room_sequence) <> 'integer' OR room_sequence <= 0
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        if try Bool.fetchOne(db, sql: """
            SELECT EXISTS (
                SELECT 1 FROM v2_reaction_effects AS live JOIN \(receipts) AS incoming
                    ON incoming.source_event_id = live.source_event_id AND incoming.message_id = live.message_id
                    AND incoming.actor_user_id = live.actor_user_id AND incoming.reaction = live.reaction
                WHERE incoming.room_id <> live.room_id OR incoming.room_sequence <> live.room_sequence
                    OR incoming.canonical_digest <> live.canonical_digest
            )
            """) == true { throw V2ClientProjectionError.invalidMessagePayload }
        try db.execute(sql: """
            INSERT INTO \(snapshotShadowTable(for: "v2_reaction_effects"))
            SELECT effect.* FROM v2_reaction_effects AS effect
            JOIN \(snapshotShadowTable(for: "v2_reaction_versions")) AS state
              ON state.message_id = effect.message_id AND state.room_id = effect.room_id
             AND state.actor_user_id = effect.actor_user_id AND state.reaction = effect.reaction
             AND state.room_sequence >= effect.room_sequence
            ON CONFLICT DO NOTHING
            """)
    }

    static func decodeMessageProjection(_ row: Row) throws -> V2ClientMessageProjection {
        let sourceEventID = try EventID(row["source_event_id"] as String)
        let messageID = try MessageID(row["message_id"] as String)
        let roomID = try RoomID(row["room_id"] as String)
        let senderUserID = try UserID(row["sender_user_id"] as String)
        let text: String = row["text_body"]
        let roomSequence = try projectionStorageUnsigned(row, column: "room_sequence")
        let timelineSequence = try projectionStorageUnsigned(row, column: "timeline_sequence")
        let messageRevision = try projectionStorageUnsigned(row, column: "message_revision")
        let media = try decodeMedia(row["media_ids"])
        let mediaPresentations = try decodeMediaPresentations(row["media_presentations"])
        let mentions = try decodeMentions(row["mention_targets"])
        let entities = try decodeEntities(row["entities"], text: text)
        let replyTo = try (row["reply_to_message_id"] as String?).map { try V2MessageReplyReference(messageID: .init($0)) }
        let forwardedFromMessageID: String? = row["forwarded_from_message_id"]
        let forwardedFromUserID: String? = row["forwarded_from_user_id"]
        let forwardedFrom: V2ForwardedMessageAttribution?
        switch (forwardedFromMessageID, forwardedFromUserID) {
        case (nil, nil):
            forwardedFrom = nil
        case let (.some(messageID), .some(userID)) where !messageID.isEmpty && !userID.isEmpty:
            forwardedFrom = try .init(messageID: .init(messageID), senderUserID: .init(userID))
        default:
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return .init(
            sourceEventID: sourceEventID,
            messageID: messageID,
            roomID: roomID,
            roomSequence: roomSequence,
            timelineSequence: timelineSequence,
            messageRevision: messageRevision,
            senderUserID: senderUserID,
            text: text,
            media: media,
            mediaPresentations: mediaPresentations,
            mentions: mentions,
            entities: entities,
            replyTo: replyTo,
            forwardedFrom: forwardedFrom,
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double),
            isWithdrawn: (row["is_withdrawn"] as Int64) != 0
        )
    }

    private static func decodeTimelineActivity(_ row: Row) throws -> V2ClientTimelineActivityProjection {
        guard let kind = V2ClientTimelineActivityProjection.Kind(rawValue: row["event_type"] as String) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            roomID: .init(row["room_id"] as String),
            timelineSequence: projectionStorageUnsigned(row, column: "timeline_sequence"),
            kind: kind,
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double)
        )
    }

    private static func decodeModerationProjection(_ row: Row) throws -> V2ClientModerationProjection {
        let sequence = UInt64(try effectInteger(row, "room_sequence"))
        return try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            roomID: .init(row["room_id"] as String), roomSequence: sequence,
            actorUserID: .init(row["actor_user_id"] as String),
            targetUserID: .init(row["target_user_id"] as String),
            muteUntil: Date(timeIntervalSince1970: row["mute_until"] as Double),
            createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double)
        )
    }



    static func encodeMedia(_ media: [V2MediaReference]) throws -> String {
        guard media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count,
              let encoded = String(data: try JSONEncoder().encode(media.map { $0.mediaID.rawValue }), encoding: .utf8)
        else { throw V2ClientCommandError.commandConflict }
        return encoded
    }

    static func decodeMedia(_ encoded: String) throws -> [V2MediaReference] {
        let rawIDs: [String]
        do { rawIDs = try JSONDecoder().decode([String].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        let media = try rawIDs.map { try V2MediaReference(mediaID: .init($0)) }
        guard media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(media).count == media.count
        else { throw V2ClientCommandError.commandConflict }
        return media
    }

    private struct MediaPresentationWire: Codable {
        let mediaID: String
        let kind: V2MediaPresentation.Kind
        let contentType: String
        let byteCount: Int64
        let resourceDescriptor: V2ResourceDescriptor?

        init(_ presentation: V2MediaPresentation) {
            mediaID = presentation.mediaID.rawValue
            kind = presentation.kind
            contentType = presentation.contentType
            byteCount = presentation.byteCount
            resourceDescriptor = presentation.resourceDescriptor
        }

        func presentation() throws -> V2MediaPresentation {
            try .init(mediaID: .init(mediaID), kind: kind, contentType: contentType, byteCount: byteCount, resourceDescriptor: resourceDescriptor)
        }

        enum CodingKeys: String, CodingKey {
            case mediaID = "media_id"
            case kind
            case contentType = "content_type"
            case byteCount = "byte_count"
            case resourceDescriptor = "resource_descriptor"
        }
    }

    static func encodeMediaPresentations(_ presentations: [V2MediaPresentation]) throws -> String {
        guard let encoded = String(data: try JSONEncoder().encode(presentations.map(MediaPresentationWire.init)), encoding: .utf8) else {
            throw V2ClientCommandError.commandConflict
        }
        return encoded
    }

    static func decodeMediaPresentations(_ encoded: String) throws -> [V2MediaPresentation] {
        let wire: [MediaPresentationWire]
        do { wire = try JSONDecoder().decode([MediaPresentationWire].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        return try wire.map { try $0.presentation() }
    }

    private struct MentionWire: Codable { let kind: String; let userID: String?; enum CodingKeys: String, CodingKey { case kind; case userID = "user_id" } }
    static func encodeMentions(_ mentions: [V2MentionTarget]) throws -> String {
        guard mentions.count <= V2MessageCommandLimits.maxMentions,
              Set(mentions).count == mentions.count
        else { throw V2ClientCommandError.commandConflict }
        let wire = mentions.map { target -> MentionWire in
            switch target { case .user(let userID): .init(kind: "user", userID: userID.rawValue); case .everyone: .init(kind: "everyone", userID: nil) }
        }
        guard let encoded = String(data: try JSONEncoder().encode(wire), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }
    static func decodeMentions(_ encoded: String) throws -> [V2MentionTarget] {
        let wire: [MentionWire]
        do { wire = try JSONDecoder().decode([MentionWire].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        let mentions = try wire.map { value -> V2MentionTarget in
            switch value.kind { case "user": guard let userID = value.userID else { throw V2ClientCommandError.commandConflict }; return .user(try .init(userID)); case "everyone": guard value.userID == nil else { throw V2ClientCommandError.commandConflict }; return .everyone; default: throw V2ClientCommandError.commandConflict }
        }
        guard mentions.count <= V2MessageCommandLimits.maxMentions, Set(mentions).count == mentions.count else { throw V2ClientCommandError.commandConflict }
        return mentions
    }

    static func encodeEntities(_ entities: [V2MessageEntity], text: String) throws -> String {
        try V2RichMessageContent.validate(text: text, entities: entities)
        guard let encoded = String(data: try JSONEncoder().encode(entities), encoding: .utf8) else { throw V2ClientCommandError.commandConflict }
        return encoded
    }

    static func decodeEntities(_ encoded: String, text: String) throws -> [V2MessageEntity] {
        let entities: [V2MessageEntity]
        do { entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(encoded.utf8)) }
        catch { throw V2ClientCommandError.commandConflict }
        try V2RichMessageContent.validate(text: text, entities: entities)
        return entities
    }



    static func decodeRoomControlProjection(_ row: Row) throws -> V2ClientRoomControlProjection {
        let sourceEventID: EventID = try .init(row["source_event_id"] as String)
        let roomID: RoomID = try .init(row["room_id"] as String)
        let actorUserID: UserID = try .init(row["actor_user_id"] as String)
        let sequence = try projectionStorageUnsigned(row, column: "room_sequence")
        guard sequence > 0 else { throw V2ClientProjectionError.invalidMessagePayload }
        return try .init(sourceEventID: sourceEventID, roomID: roomID, roomSequence: sequence, actorUserID: actorUserID, isFrozen: row["is_frozen"], createdAt: Date(timeIntervalSince1970: row["server_created_at"] as Double))
    }

    static func decodeRoomProfileProjection(_ row: Row) throws -> V2ClientRoomProfileProjection {
        guard let capacityClass = V2GroupCapacityClass(rawValue: row["capacity_class"] as String) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        return try .init(
            sourceEventID: .init(row["source_event_id"] as String),
            roomID: .init(row["room_id"] as String),
            title: row["title"],
            ownerUserID: .init(row["owner_user_id"] as String),
            capacityClass: capacityClass,

            membershipRevision: storageUnsigned(row, column: "membership_revision"),
            createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
        )
    }

    static func decodeDirectRoomIdentity(_ row: Row) throws -> V2ClientDirectRoomIdentity {
        guard let accountKind = V2AccountKind(rawValue: row["account_kind"] as String) else {
            throw V2ClientProjectionError.invalidMessagePayload
        }
        let identity = try V2PublicIdentity(
            userID: .init(row["target_user_id"] as String),
            handle: .init(row["public_handle"] as String),
            displayName: row["display_name"] as String,
            accountKind: accountKind
        )
        return try .init(
            roomID: .init(row["room_id"] as String),
            publicIdentity: identity,
            updatedAt: Date(timeIntervalSince1970: row["updated_at"] as Double),
            roomCreatedAt: Date(timeIntervalSince1970: row["room_created_at"] as Double)
        )
    }



    enum V2MessageSearchRebuildOutcome {
        case advanced(Int64)
        case finished
        case restartRequired
    }


    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCurrentV2Schema") { db in
            try db.execute(sql: currentSchemaSQL)
            try db.execute(sql: operationWorkSchemaSQL)
            try db.execute(sql: profileIntentSchemaSQL)
            try db.execute(sql: personalPreferenceIntentSchemaSQL)
            try db.execute(sql: nameOperationSchemaSQL)
            try db.execute(sql: readReceiptWorkSchemaSQL)
            try db.execute(sql: messageMutationWorkSchemaSQL)
            try db.execute(sql: socialOperationWorkSchemaSQL)
            try db.execute(sql: socialProposalSchemaSQL)
            try db.execute(sql: accountPreferenceWorkSchemaSQL)
            try db.execute(sql: accountPreferenceDraftSchemaSQL)
            try db.execute(sql: accountPreferenceAuthorityCacheSchemaSQL)
            try db.execute(sql: messageReactionWorkSchemaSQL)
            try db.execute(sql: messageSendWorkSchemaSQL)
            try db.execute(sql: forwardPlanWorkSchemaSQL)
            try db.execute(sql: memberAdministrationWorkSchemaSQL)
            try db.execute(sql: membershipWorkSchemaSQL)
            try db.execute(sql: invitationWorkSchemaSQL)
            try db.execute(sql: groupCapabilityWorkSchemaSQL)
            try db.execute(sql: groupCreationWorkSchemaSQL)
            try db.execute(sql: directRoomWorkSchemaSQL)
            try db.execute(sql: messageModerationWorkSchemaSQL)
            for statement in resourceSchemaStatements { try db.execute(sql: statement) }
            try db.execute(sql: groupAvatarInvalidationSchemaSQL)
            try db.execute(sql: groupAvatarIntentsSchemaSQL)
            try db.execute(sql: groupNicknameInvalidationSchemaSQL)
            try db.execute(sql: localDirectMessagesSchemaSQL)
            try db.execute(sql: localProfileDisplaySchemaSQL)
        }
        return migrator
    }()

    static let messageSearchMigrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCurrentV2MessageSearchSchema") { db in
            try db.execute(sql: """
                CREATE TABLE v2_search_documents (
                    message_id TEXT PRIMARY KEY,
                    message_revision INTEGER NOT NULL CHECK (message_revision > 0),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    room_id TEXT NOT NULL,
                    room_sequence INTEGER NOT NULL CHECK (room_sequence > 0),
                    sender_user_id TEXT NOT NULL,
                    text_body TEXT NOT NULL,
                    media_presentations TEXT NOT NULL,
                    server_created_at REAL NOT NULL
                );
                CREATE INDEX v2_search_documents_room_order_idx
                    ON v2_search_documents (room_id, room_sequence DESC, message_id DESC);
                CREATE INDEX v2_search_documents_global_order_idx
                    ON v2_search_documents (server_created_at DESC, message_id DESC);
                CREATE INDEX v2_search_documents_sender_order_idx
                    ON v2_search_documents (sender_user_id, server_created_at DESC, message_id DESC);
                CREATE VIRTUAL TABLE v2_message_char_fts USING fts5(
                    room_scope,
                    sender_scope,
                    unigrams,
                    bigrams,
                    tokenize = 'ascii',
                    detail = full,
                    columnsize = 0
                );
            """)
        }
        return migrator
    }()

}

private enum TimelinePageCandidate {
    case message(V2ClientMessageProjection)
    case activity(V2ClientTimelineActivityProjection)

    var timelineSequence: UInt64 {
        switch self {
        case .message(let message): message.timelineSequence
        case .activity(let activity): activity.timelineSequence
        }
    }

    var itemID: String {
        switch self {
        case .message(let message): message.messageID.rawValue
        case .activity(let activity): activity.sourceEventID.rawValue
        }
    }

    var cursor: V2ClientTimelineCursor {
        .init(timelineSequence: timelineSequence, itemID: itemID, kind: kind)
    }

    var kind: V2ClientTimelineItemKind {
        switch self { case .message: .message; case .activity: .activity }
    }

    var message: V2ClientMessageProjection? {
        guard case .message(let message) = self else { return nil }
        return message
    }

    var activity: V2ClientTimelineActivityProjection? {
        guard case .activity(let activity) = self else { return nil }
        return activity
    }

    static func newerFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        olderFirst(rhs, lhs)
    }

    static func olderFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.timelineSequence != rhs.timelineSequence { return lhs.timelineSequence < rhs.timelineSequence }
        if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

public enum V2LocalBackupExclusion {
    public static func apply(to url: URL) throws {
        // The exclusion bit is an Apple backup-service guarantee. Linux has
        // no equivalent resource value, so asserting it there would turn a
        // portable SQLite regression into a false failure. Linux callers are
        // intentionally not told the database is backup-safe.
        #if canImport(Darwin)
        do {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
            let verified = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            guard verified == true else { throw V2ClientLocalStorageError.backupExclusionVerificationFailed }
        } catch {
            // XCTest uses the process temporary directory, which is already
            // excluded from device backup but does not consistently support
            // NSURLIsExcludedFromBackupKey (notably APFS temp volumes return
            // writErr).  Do not weaken the production storage invariant: the
            // exception is confined to FileManager's ephemeral temp root.
            guard isEphemeralTemporaryPath(url) else { throw error }
        }
        #else
        _ = url
        #endif
    }

    #if canImport(Darwin)
    private static func isEphemeralTemporaryPath(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        return candidate == temporaryRoot || candidate.hasPrefix(temporaryRoot + "/")
    }
    #endif
}

public enum V2ClientLocalStorageError: Error, Equatable, Sendable {
    case unsupportedResourceSchema
    case backupExclusionVerificationFailed
    case installationBindingMismatch
}

private extension Optional where Wrapped == V2LocalSyncCursor.State {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
