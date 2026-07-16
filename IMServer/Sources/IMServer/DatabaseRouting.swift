import Fluent
import FluentPostgresDriver
import NIOConcurrencyHelpers
import SQLKit
import Vapor

extension DatabaseID {
    static let imReplica = DatabaseID(string: "im-replica")
    static let imSummary = DatabaseID(string: "im-summary")
}

struct RoutedShardDatabase {
    let shardID: String
    let database: any Database
}

struct ConversationRoute: Sendable, Equatable {
    let cellID: String
    let shardID: String
    let version: Int

    init(cellID: String, shardID: String, version: Int = 1) {
        self.cellID = cellID
        self.shardID = shardID
        self.version = version
    }
}

private struct IMReplicaDatabaseEnabledStorageKey: StorageKey {
    typealias Value = Bool
}

private struct IMSummaryDatabaseEnabledStorageKey: StorageKey {
    typealias Value = Bool
}

private struct ConversationShardDatabaseIDsStorageKey: StorageKey {
    typealias Value = [String: DatabaseID]
}

private struct ConversationShardReplicaDatabaseIDsStorageKey: StorageKey {
    typealias Value = [String: DatabaseID]
}

private struct SummaryShardDatabaseIDsStorageKey: StorageKey {
    typealias Value = [String: DatabaseID]
}

private struct ConversationShardRoutingConfigurationStorageKey: StorageKey {
    typealias Value = IMConversationShardRoutingConfiguration
}

protocol ConversationShardRouter: Sendable {
    var routerName: String { get }
    var shardIDs: [String] { get }
    func commandDatabase() -> any Database
    func commandDatabase(forShardID shardID: String) -> any Database
    func strongReadDatabase() -> any Database
    func eventualReadDatabase() -> any Database
    func strongReadDatabase(forShardID shardID: String) -> any Database
    func eventualReadDatabase(forShardID shardID: String) -> any Database
    func shardID(forNewConversationID conversationID: UUID) -> String
    func shardID(forConversationID conversationID: UUID) async throws -> String
    func commandDatabase(forConversationID conversationID: UUID) async throws -> any Database
    func strongReadDatabase(forConversationID conversationID: UUID) async throws -> any Database
    func eventualReadDatabase(forConversationID conversationID: UUID) async throws -> any Database
    func allCommandDatabases() -> [RoutedShardDatabase]
}

protocol SummaryShardRouter: Sendable {
    var routerName: String { get }
    var shardIDs: [String] { get }
    func shardID(forOwnerUserID userID: UUID) -> String
    func database(forShardID shardID: String) -> any Database
    func database(forOwnerUserID userID: UUID) -> any Database
}

protocol ConversationDirectory: Sendable {
    func shardID(for conversationID: UUID) async throws -> String
    func registerConversation(conversationID: UUID, shardID: String) async throws
    func route(for conversationID: UUID) async throws -> ConversationRoute
    func registerConversation(conversationID: UUID, shardID: String, cellID: String) async throws
    func reserveConversation(conversationID: UUID, shardID: String, cellID: String) async throws
    func activateConversation(conversationID: UUID) async throws
    func cutoverConversation(
        conversationID: UUID,
        expectedRoute: ConversationRoute,
        targetCellID: String,
        targetShardID: String
    ) async throws -> ConversationRoute
}

extension ConversationDirectory {
    func route(for conversationID: UUID) async throws -> ConversationRoute {
        ConversationRoute(
            cellID: IMRealtimeCellConfiguration.defaultCellID,
            shardID: try await shardID(for: conversationID)
        )
    }

    func registerConversation(conversationID: UUID, shardID: String, cellID _: String) async throws {
        try await registerConversation(conversationID: conversationID, shardID: shardID)
    }

    func reserveConversation(conversationID: UUID, shardID: String, cellID: String) async throws {
        try await registerConversation(conversationID: conversationID, shardID: shardID, cellID: cellID)
    }

    func activateConversation(conversationID _: UUID) async throws { }

    func cutoverConversation(
        conversationID _: UUID,
        expectedRoute _: ConversationRoute,
        targetCellID _: String,
        targetShardID _: String
    ) async throws -> ConversationRoute {
        throw Abort(.notImplemented, reason: "This conversation directory does not support physical shard cutover.")
    }
}

protocol DirectConversationIndex: Sendable {
    func shardID(forMemberUserIDs memberUserIDs: [UUID]) async throws -> String
    func conversationID(forMemberUserIDs memberUserIDs: [UUID]) async throws -> UUID?
    func reserveDirectConversation(
        conversationID: UUID,
        memberUserIDs: [UUID],
        shardID: String
    ) async throws -> DirectConversationIndexReservation
    func releaseDirectConversationReservation(
        conversationID: UUID,
        memberUserIDs: [UUID]
    ) async throws
    func registerDirectConversation(
        conversationID: UUID,
        memberUserIDs: [UUID],
        shardID: String
    ) async throws
}

enum DirectConversationIndexReservation: Sendable, Equatable {
    case reserved
    case existing(conversationID: UUID)
}

private struct ConversationShardRouterStorageKey: StorageKey {
    typealias Value = any ConversationShardRouter
}

private struct ConversationDirectoryStorageKey: StorageKey {
    typealias Value = any ConversationDirectory
}

private struct DirectConversationIndexStorageKey: StorageKey {
    typealias Value = any DirectConversationIndex
}

private struct SummaryShardRouterStorageKey: StorageKey {
    typealias Value = any SummaryShardRouter
}

struct SingleShardConversationShardRouter: ConversationShardRouter {
    let app: Application
    static let defaultShardID = "shard-0"

    var routerName: String { "single-shard" }
    var shardIDs: [String] { [Self.defaultShardID] }

    func commandDatabase() -> any Database {
        app.db
    }

    func commandDatabase(forShardID shardID: String) -> any Database {
        commandDatabase()
    }

    func strongReadDatabase() -> any Database {
        app.db
    }

    func eventualReadDatabase() -> any Database {
        app.imReplicaDatabaseEnabled ? app.db(.imReplica) : app.db
    }

    func strongReadDatabase(forShardID shardID: String) -> any Database {
        strongReadDatabase()
    }

    func eventualReadDatabase(forShardID shardID: String) -> any Database {
        eventualReadDatabase()
    }

    func shardID(forNewConversationID conversationID: UUID) -> String {
        Self.defaultShardID
    }

    func shardID(forConversationID conversationID: UUID) async throws -> String {
        Self.defaultShardID
    }

    func commandDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        commandDatabase()
    }

    func strongReadDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        strongReadDatabase()
    }

    func eventualReadDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        eventualReadDatabase()
    }

    func allCommandDatabases() -> [RoutedShardDatabase] {
        [RoutedShardDatabase(shardID: Self.defaultShardID, database: commandDatabase())]
    }
}

struct DirectoryBackedConversationShardRouter: ConversationShardRouter {
    let app: Application
    let shardIDs: [String]
    let shardDatabaseIDs: [String: DatabaseID]
    let shardReplicaDatabaseIDs: [String: DatabaseID]
    let directory: any ConversationDirectory
    private let routeCache: ConversationRouteLookupCache

    init(
        app: Application,
        shardIDs: [String],
        shardDatabaseIDs: [String: DatabaseID],
        shardReplicaDatabaseIDs: [String: DatabaseID],
        directory: any ConversationDirectory
    ) {
        self.app = app
        self.shardIDs = shardIDs
        self.shardDatabaseIDs = shardDatabaseIDs
        self.shardReplicaDatabaseIDs = shardReplicaDatabaseIDs
        self.directory = directory
        self.routeCache = ConversationRouteLookupCache(
            maxEntries: app.conversationShardRoutingConfiguration.directoryCacheMaxEntries,
            ttl: app.conversationShardRoutingConfiguration.directoryCacheTTL
        )
    }

    var routerName: String { "directory-backed-conversation-shard" }

    func commandDatabase() -> any Database {
        database(forShardID: shardIDs.first ?? SingleShardConversationShardRouter.defaultShardID)
    }

    func commandDatabase(forShardID shardID: String) -> any Database {
        database(forShardID: shardID)
    }

    func strongReadDatabase() -> any Database {
        commandDatabase()
    }

    func eventualReadDatabase() -> any Database {
        eventualDatabase(forShardID: shardIDs.first ?? SingleShardConversationShardRouter.defaultShardID)
    }

    func strongReadDatabase(forShardID shardID: String) -> any Database {
        database(forShardID: shardID)
    }

    func eventualReadDatabase(forShardID shardID: String) -> any Database {
        eventualDatabase(forShardID: shardID)
    }

    func shardID(forNewConversationID conversationID: UUID) -> String {
        stableShardID(for: conversationID, shardIDs: shardIDs)
    }

    func shardID(forConversationID conversationID: UUID) async throws -> String {
        if let cachedRoute = routeCache.route(for: conversationID),
           cachedRoute.cellID == app.imRealtimeCellID,
           shardIDs.contains(cachedRoute.shardID) {
            await app.conversationShardRoutingMetrics.recordCacheHit()
            return cachedRoute.shardID
        }

        await app.conversationShardRoutingMetrics.recordCacheMiss()
        let lookupStartedAt = Date()
        let route: ConversationRoute
        do {
            route = try await directory.route(for: conversationID)
        } catch {
            await app.conversationShardRoutingMetrics.recordDirectoryLookupFailure(
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(lookupStartedAt) * 1_000))
            )
            throw error
        }
        await app.conversationShardRoutingMetrics.recordDirectoryLookup(
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(lookupStartedAt) * 1_000))
        )
        guard route.cellID == app.imRealtimeCellID else {
            await app.conversationShardRoutingMetrics.recordRemoteCellRouteRejected()
            throw Abort(
                .serviceUnavailable,
                reason: "Conversation \(conversationID.uuidString) belongs to realtime cell \(route.cellID), not local cell \(app.imRealtimeCellID)."
            )
        }
        if shardIDs.contains(route.shardID) {
            let storeResult = routeCache.store(route, for: conversationID)
            await app.conversationShardRoutingMetrics.recordCacheStore(
                entryCount: storeResult.entryCount,
                evictedCount: storeResult.evictedCount,
                maxEntries: routeCache.maxEntries
            )
            return route.shardID
        }
        throw Abort(
            .internalServerError,
            reason: "Conversation shard directory references unknown shard \(route.shardID) for conversation \(conversationID)."
        )
    }

    func commandDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        let shardID = try await shardID(forConversationID: conversationID)
        return database(forShardID: shardID)
    }

    func strongReadDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        let shardID = try await shardID(forConversationID: conversationID)
        return database(forShardID: shardID)
    }

    func eventualReadDatabase(forConversationID conversationID: UUID) async throws -> any Database {
        let shardID = try await shardID(forConversationID: conversationID)
        return eventualDatabase(forShardID: shardID)
    }

    func allCommandDatabases() -> [RoutedShardDatabase] {
        shardIDs.map { shardID in
            RoutedShardDatabase(
                shardID: shardID,
                database: database(forShardID: shardID)
            )
        }
    }

    private func database(forShardID shardID: String) -> any Database {
        if let databaseID = shardDatabaseIDs[shardID] {
            return app.db(databaseID)
        }
        return app.db
    }

    private func eventualDatabase(forShardID shardID: String) -> any Database {
        if let databaseID = shardReplicaDatabaseIDs[shardID] {
            return app.db(databaseID)
        }
        if let databaseID = shardDatabaseIDs[shardID] {
            return app.db(databaseID)
        }
        return app.imReplicaDatabaseEnabled ? app.db(.imReplica) : app.db
    }
}

struct IMConversationShardRoutingConfiguration: Sendable {
    static let defaultDirectoryCacheMaxEntries = 20_000
    static let defaultDirectoryCacheTTLSeconds = 15

    let directoryCacheMaxEntries: Int
    let directoryCacheTTLSeconds: Int

    var directoryCacheTTL: TimeInterval {
        TimeInterval(directoryCacheTTLSeconds)
    }

    init(
        directoryCacheMaxEntries: Int = defaultDirectoryCacheMaxEntries,
        directoryCacheTTLSeconds: Int = defaultDirectoryCacheTTLSeconds
    ) {
        self.directoryCacheMaxEntries = max(1, directoryCacheMaxEntries)
        self.directoryCacheTTLSeconds = max(1, directoryCacheTTLSeconds)
    }

    static func load(from environment: Environment) -> Self {
        .init(
            directoryCacheMaxEntries: Environment.get("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_MAX_ENTRIES")
                .flatMap(Int.init(_:)) ?? defaultDirectoryCacheMaxEntries,
            directoryCacheTTLSeconds: Environment.get("IM_CONVERSATION_SHARD_DIRECTORY_CACHE_TTL_SECONDS")
                .flatMap(Int.init(_:)) ?? defaultDirectoryCacheTTLSeconds
        )
    }
}

private final class ConversationRouteLookupCache: @unchecked Sendable {
    struct StoreResult: Sendable {
        let entryCount: Int
        let evictedCount: Int
    }

    private struct Entry {
        var route: ConversationRoute
        var expiresAt: Date
        var recency: UInt64
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        var recencyQueue: [(conversationID: UUID, recency: UInt64)] = []
        var nextRecency: UInt64 = 0
    }

    let maxEntries: Int
    private let ttl: TimeInterval
    private let state = NIOLockedValueBox(State())

    init(maxEntries: Int, ttl: TimeInterval) {
        self.maxEntries = max(1, maxEntries)
        self.ttl = max(1, ttl)
    }

    func route(for conversationID: UUID) -> ConversationRoute? {
        state.withLockedValue { state in
            guard var entry = state.entries[conversationID] else {
                return nil
            }
            guard entry.expiresAt > Date() else {
                state.entries.removeValue(forKey: conversationID)
                return nil
            }
            entry.recency = nextRecency(in: &state)
            state.entries[conversationID] = entry
            state.recencyQueue.append((conversationID, entry.recency))
            compactRecencyQueueIfNeeded(&state)
            return entry.route
        }
    }

    func store(_ route: ConversationRoute, for conversationID: UUID) -> StoreResult {
        state.withLockedValue { state in
            let recency = nextRecency(in: &state)
            state.entries[conversationID] = Entry(
                route: route,
                expiresAt: Date().addingTimeInterval(ttl),
                recency: recency
            )
            state.recencyQueue.append((conversationID, recency))
            let evictedCount = trimIfNeeded(&state)
            compactRecencyQueueIfNeeded(&state)
            return StoreResult(entryCount: state.entries.count, evictedCount: evictedCount)
        }
    }

    private func nextRecency(in state: inout State) -> UInt64 {
        state.nextRecency &+= 1
        if state.nextRecency == 0 {
            state.nextRecency = 1
        }
        return state.nextRecency
    }

    private func trimIfNeeded(_ state: inout State) -> Int {
        var evictedCount = 0
        while state.entries.count > maxEntries, !state.recencyQueue.isEmpty {
            let candidate = state.recencyQueue.removeFirst()
            guard state.entries[candidate.conversationID]?.recency == candidate.recency else {
                continue
            }
            state.entries[candidate.conversationID] = nil
            evictedCount += 1
        }
        return evictedCount
    }

    private func compactRecencyQueueIfNeeded(_ state: inout State) {
        guard state.recencyQueue.count > maxEntries * 4 else {
            return
        }
        state.recencyQueue.removeAll { candidate in
            state.entries[candidate.conversationID]?.recency != candidate.recency
        }
    }
}

struct SingleSummaryShardRouter: SummaryShardRouter {
    let app: Application
    let shardID: String

    var routerName: String { "single-summary-shard" }
    var shardIDs: [String] { [shardID] }

    func shardID(forOwnerUserID userID: UUID) -> String {
        shardID
    }

    func database(forShardID shardID: String) -> any Database {
        app.imSummaryDB
    }

    func database(forOwnerUserID userID: UUID) -> any Database {
        app.imSummaryDB
    }
}

struct OwnerHashSummaryShardRouter: SummaryShardRouter {
    let app: Application
    let shardIDs: [String]
    let shardDatabaseIDs: [String: DatabaseID]

    var routerName: String { "owner-hash-summary-shard" }

    func shardID(forOwnerUserID userID: UUID) -> String {
        guard shardIDs.count > 1 else {
            return shardIDs.first ?? IMSummaryStoreConfiguration.defaultShardID
        }
        let uuidTuple = userID.uuid
        let bytes: [UInt8] = [
            uuidTuple.0, uuidTuple.1, uuidTuple.2, uuidTuple.3,
            uuidTuple.4, uuidTuple.5, uuidTuple.6, uuidTuple.7,
            uuidTuple.8, uuidTuple.9, uuidTuple.10, uuidTuple.11,
            uuidTuple.12, uuidTuple.13, uuidTuple.14, uuidTuple.15
        ]
        let bucket = bytes.reduce(UInt64(0)) { accumulator, byte in
            ((accumulator << 5) &+ accumulator) &+ UInt64(byte)
        }
        let index = Int(bucket % UInt64(shardIDs.count))
        return shardIDs[index]
    }

    func database(forOwnerUserID userID: UUID) -> any Database {
        let shardID = shardID(forOwnerUserID: userID)
        return database(forShardID: shardID)
    }

    func database(forShardID shardID: String) -> any Database {
        if let databaseID = shardDatabaseIDs[shardID] {
            return app.db(databaseID)
        }
        return app.imSummaryDB
    }
}

struct DatabaseConversationDirectory: ConversationDirectory {
    let db: any Database
    let localCellID: String

    init(db: any Database, localCellID: String = IMRealtimeCellConfiguration.defaultCellID) {
        self.db = db
        self.localCellID = localCellID
    }

    func shardID(for conversationID: UUID) async throws -> String {
        let route = try await route(for: conversationID)
        guard route.cellID == localCellID else {
            throw Abort(
                .serviceUnavailable,
                reason: "Conversation \(conversationID.uuidString) belongs to realtime cell \(route.cellID), not local cell \(localCellID)."
            )
        }
        return route.shardID
    }

    func registerConversation(conversationID: UUID, shardID: String) async throws {
        try await registerConversation(
            conversationID: conversationID,
            shardID: shardID,
            cellID: localCellID
        )
    }

    func route(for conversationID: UUID) async throws -> ConversationRoute {
        if let entry = try await ConversationDirectoryEntry.find(conversationID, on: db) {
            guard entry.lifecycleState == .active else {
                throw Abort(
                    .serviceUnavailable,
                    reason: "Conversation \(conversationID.uuidString) route is \(entry.lifecycleState.rawValue) and is not ready."
                )
            }
            return ConversationRoute(
                cellID: entry.cellID,
                shardID: entry.shardID,
                version: entry.routeVersion
            )
        }
        throw Abort(
            .notFound,
            reason: "Conversation \(conversationID.uuidString) is not registered in the conversation directory."
        )
    }

    func registerConversation(conversationID: UUID, shardID: String, cellID: String) async throws {
        try await reserveConversation(
            conversationID: conversationID,
            shardID: shardID,
            cellID: cellID
        )
        try await activateConversation(conversationID: conversationID)
    }

    func reserveConversation(conversationID: UUID, shardID: String, cellID: String) async throws {
        if let entry = try await ConversationDirectoryEntry.find(conversationID, on: db) {
            guard entry.shardID == shardID, entry.cellID == cellID else {
                throw Abort(
                    .conflict,
                    reason: "Conversation \(conversationID.uuidString) already reserves route \(entry.cellID)/\(entry.shardID)."
                )
            }
            if entry.lifecycleState == .abandoned {
                entry.lifecycleState = .pending
                entry.routeVersion += 1
                entry.activatedAt = nil
                try await entry.update(on: db)
            }
            return
        }
        try await ConversationDirectoryEntry(
            conversationID: conversationID,
            shardID: shardID,
            cellID: cellID,
            lifecycleState: .pending
        ).create(on: db)
    }

    func activateConversation(conversationID: UUID) async throws {
        guard let entry = try await ConversationDirectoryEntry.find(conversationID, on: db) else {
            return
        }
        guard entry.lifecycleState == .pending else {
            return
        }
        entry.lifecycleState = .active
        entry.activatedAt = Date()
        try await entry.update(on: db)
    }

    func cutoverConversation(
        conversationID: UUID,
        expectedRoute: ConversationRoute,
        targetCellID: String,
        targetShardID: String
    ) async throws -> ConversationRoute {
        guard !targetCellID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !targetShardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw Abort(.badRequest, reason: "Conversation cutover target route is incomplete.")
        }

        return try await db.transaction { transaction in
            if let sql = transaction as? any SQLDatabase,
               sql.dialect.name == "postgresql" {
                try await sql.raw("""
                    SELECT conversation_id
                    FROM conversation_directory
                    WHERE conversation_id = \(bind: conversationID)
                    FOR UPDATE
                    """).run()
            }
            guard let entry = try await ConversationDirectoryEntry.find(conversationID, on: transaction) else {
                throw Abort(.notFound, reason: "Conversation is not registered in the conversation directory.")
            }
            guard entry.lifecycleState == .active,
                  entry.cellID == expectedRoute.cellID,
                  entry.shardID == expectedRoute.shardID,
                  entry.routeVersion == expectedRoute.version
            else {
                throw Abort(.conflict, reason: "Conversation route changed before shard cutover could commit.")
            }

            entry.cellID = targetCellID
            entry.shardID = targetShardID
            entry.routeVersion += 1
            try await entry.update(on: transaction)
            return ConversationRoute(
                cellID: entry.cellID,
                shardID: entry.shardID,
                version: entry.routeVersion
            )
        }
    }
}

struct DatabaseDirectConversationIndex: DirectConversationIndex {
    let db: any Database

    func shardID(forMemberUserIDs memberUserIDs: [UUID]) async throws -> String {
        if let entry = try await entry(forMemberUserIDs: memberUserIDs) {
            return entry.shardID
        }
        return SingleShardConversationShardRouter.defaultShardID
    }

    func conversationID(forMemberUserIDs memberUserIDs: [UUID]) async throws -> UUID? {
        try await entry(forMemberUserIDs: memberUserIDs)?.conversationID
    }

    func reserveDirectConversation(
        conversationID: UUID,
        memberUserIDs: [UUID],
        shardID: String
    ) async throws -> DirectConversationIndexReservation {
        let pairHash = Self.pairHash(for: memberUserIDs)
        guard !pairHash.isEmpty else {
            throw Abort(.badRequest, reason: "A direct conversation requires exactly two members.")
        }
        if let existing = try await DirectConversationIndexEntry.find(pairHash, on: db) {
            return .existing(conversationID: existing.conversationID)
        }

        do {
            try await DirectConversationIndexEntry(
                pairHash: pairHash,
                conversationID: conversationID,
                shardID: shardID
            ).create(on: db)
            return .reserved
        } catch {
            if let existing = try await DirectConversationIndexEntry.find(pairHash, on: db) {
                return .existing(conversationID: existing.conversationID)
            }
            throw error
        }
    }

    func releaseDirectConversationReservation(
        conversationID: UUID,
        memberUserIDs: [UUID]
    ) async throws {
        guard let entry = try await entry(forMemberUserIDs: memberUserIDs),
              entry.conversationID == conversationID
        else {
            return
        }
        try await entry.delete(on: db)
    }

    func registerDirectConversation(
        conversationID: UUID,
        memberUserIDs: [UUID],
        shardID: String
    ) async throws {
        let pairHash = Self.pairHash(for: memberUserIDs)
        if let existing = try await DirectConversationIndexEntry.find(pairHash, on: db) {
            existing.conversationID = conversationID
            existing.shardID = shardID
            try await existing.update(on: db)
            return
        }

        try await DirectConversationIndexEntry(
            pairHash: pairHash,
            conversationID: conversationID,
            shardID: shardID
        ).create(on: db)
    }

    private func entry(forMemberUserIDs memberUserIDs: [UUID]) async throws -> DirectConversationIndexEntry? {
        guard memberUserIDs.count == 2 else {
            return nil
        }
        return try await DirectConversationIndexEntry.find(Self.pairHash(for: memberUserIDs), on: db)
    }

    private static func pairHash(for memberUserIDs: [UUID]) -> String {
        guard memberUserIDs.count == 2 else {
            return ""
        }
        return memberUserIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: ":")
    }
}

extension Application {
    var imReplicaDatabaseEnabled: Bool {
        get { storage[IMReplicaDatabaseEnabledStorageKey.self] ?? false }
        set { storage[IMReplicaDatabaseEnabledStorageKey.self] = newValue }
    }

    var conversationShardRouter: any ConversationShardRouter {
        get {
            if let router = storage[ConversationShardRouterStorageKey.self] {
                return router
            }
            let configuredShardIDs = shardTopologyConfiguration.shardIDs
            let router: any ConversationShardRouter
            if configuredShardIDs.count > 1 || !conversationShardDatabaseIDs.isEmpty {
                router = DirectoryBackedConversationShardRouter(
                    app: self,
                    shardIDs: configuredShardIDs,
                    shardDatabaseIDs: conversationShardDatabaseIDs,
                    shardReplicaDatabaseIDs: conversationShardReplicaDatabaseIDs,
                    directory: conversationDirectory
                )
            } else {
                router = SingleShardConversationShardRouter(app: self)
            }
            storage[ConversationShardRouterStorageKey.self] = router
            return router
        }
        set { storage[ConversationShardRouterStorageKey.self] = newValue }
    }

    var conversationDirectory: any ConversationDirectory {
        get {
            if let directory = storage[ConversationDirectoryStorageKey.self] {
                return directory
            }
            let directory = DatabaseConversationDirectory(db: db, localCellID: imRealtimeCellID)
            storage[ConversationDirectoryStorageKey.self] = directory
            return directory
        }
        set { storage[ConversationDirectoryStorageKey.self] = newValue }
    }

    var conversationShardRoutingConfiguration: IMConversationShardRoutingConfiguration {
        get {
            if let configuration = storage[ConversationShardRoutingConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMConversationShardRoutingConfiguration.load(from: environment)
            storage[ConversationShardRoutingConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[ConversationShardRoutingConfigurationStorageKey.self] = newValue
        }
    }

    var directConversationIndex: any DirectConversationIndex {
        get {
            if let index = storage[DirectConversationIndexStorageKey.self] {
                return index
            }
            let index = DatabaseDirectConversationIndex(db: db)
            storage[DirectConversationIndexStorageKey.self] = index
            return index
        }
        set { storage[DirectConversationIndexStorageKey.self] = newValue }
    }

    var conversationShardDatabaseIDs: [String: DatabaseID] {
        get { storage[ConversationShardDatabaseIDsStorageKey.self] ?? [:] }
        set { storage[ConversationShardDatabaseIDsStorageKey.self] = newValue }
    }

    var conversationShardReplicaDatabaseIDs: [String: DatabaseID] {
        get { storage[ConversationShardReplicaDatabaseIDsStorageKey.self] ?? [:] }
        set { storage[ConversationShardReplicaDatabaseIDsStorageKey.self] = newValue }
    }

    var summaryShardDatabaseIDs: [String: DatabaseID] {
        get { storage[SummaryShardDatabaseIDsStorageKey.self] ?? [:] }
        set { storage[SummaryShardDatabaseIDsStorageKey.self] = newValue }
    }

    var imSummaryDatabaseEnabled: Bool {
        get { storage[IMSummaryDatabaseEnabledStorageKey.self] ?? false }
        set { storage[IMSummaryDatabaseEnabledStorageKey.self] = newValue }
    }

    var summaryShardRouter: any SummaryShardRouter {
        get {
            if let router = storage[SummaryShardRouterStorageKey.self] {
                return router
            }

            let configuredShardIDs = summaryStoreConfiguration.shardIDs
            let router: any SummaryShardRouter
            if configuredShardIDs.count > 1 || !summaryShardDatabaseIDs.isEmpty {
                router = OwnerHashSummaryShardRouter(
                    app: self,
                    shardIDs: configuredShardIDs,
                    shardDatabaseIDs: summaryShardDatabaseIDs
                )
            } else {
                router = SingleSummaryShardRouter(
                    app: self,
                    shardID: configuredShardIDs.first ?? IMSummaryStoreConfiguration.defaultShardID
                )
            }

            storage[SummaryShardRouterStorageKey.self] = router
            return router
        }
        set { storage[SummaryShardRouterStorageKey.self] = newValue }
    }

    var imWriteDB: any Database {
        conversationShardRouter.commandDatabase()
    }

    var imReadDB: any Database {
        conversationShardRouter.eventualReadDatabase()
    }

    var imStrongReadDB: any Database {
        conversationShardRouter.strongReadDatabase()
    }

    var imSummaryDB: any Database {
        imSummaryDatabaseEnabled ? db(.imSummary) : imReadDB
    }
}

extension Request {
    var imWriteDB: any Database {
        application.imWriteDB
    }

    var imReadDB: any Database {
        application.imReadDB
    }

    var imStrongReadDB: any Database {
        application.imStrongReadDB
    }
}

struct IMPostgresDatabasePairConfiguration: Sendable {
    let primary: SQLPostgresConfiguration
    let replica: SQLPostgresConfiguration?
    let conversationShards: [String: SQLPostgresConfiguration]
    let conversationShardReplicas: [String: SQLPostgresConfiguration]
    let summary: SQLPostgresConfiguration?
    let summaryShards: [String: SQLPostgresConfiguration]
}

private func stableShardID(for conversationID: UUID, shardIDs: [String]) -> String {
    guard shardIDs.count > 1 else {
        return shardIDs.first ?? SingleShardConversationShardRouter.defaultShardID
    }
    let uuidTuple = conversationID.uuid
    let bytes: [UInt8] = [
        uuidTuple.0, uuidTuple.1, uuidTuple.2, uuidTuple.3,
        uuidTuple.4, uuidTuple.5, uuidTuple.6, uuidTuple.7,
        uuidTuple.8, uuidTuple.9, uuidTuple.10, uuidTuple.11,
        uuidTuple.12, uuidTuple.13, uuidTuple.14, uuidTuple.15
    ]
    let bucket = bytes.reduce(UInt64(0)) { accumulator, byte in
        ((accumulator << 5) &+ accumulator) &+ UInt64(byte)
    }
    let index = Int(bucket % UInt64(shardIDs.count))
    return shardIDs[index]
}
