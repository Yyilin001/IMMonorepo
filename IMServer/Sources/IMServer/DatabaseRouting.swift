import Fluent
import FluentPostgresDriver
import Vapor

extension DatabaseID {
    static let imReplica = DatabaseID(string: "im-replica")
    static let imSummary = DatabaseID(string: "im-summary")
}

struct RoutedShardDatabase {
    let shardID: String
    let database: any Database
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
}

protocol DirectConversationIndex: Sendable {
    func shardID(forMemberUserIDs memberUserIDs: [UUID]) async throws -> String
    func conversationID(forMemberUserIDs memberUserIDs: [UUID]) async throws -> UUID?
    func registerDirectConversation(
        conversationID: UUID,
        memberUserIDs: [UUID],
        shardID: String
    ) async throws
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
    private let shardCache = ConversationShardIDLookupCache(maxEntries: 20_000)

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
        if let cachedShardID = await shardCache.shardID(for: conversationID),
           shardIDs.contains(cachedShardID) {
            return cachedShardID
        }

        let storedShardID = try await directory.shardID(for: conversationID)
        if shardIDs.contains(storedShardID) {
            await shardCache.store(storedShardID, for: conversationID)
            return storedShardID
        }
        throw Abort(
            .internalServerError,
            reason: "Conversation shard directory references unknown shard \(storedShardID) for conversation \(conversationID)."
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

private actor ConversationShardIDLookupCache {
    private let maxEntries: Int
    private var values: [UUID: String] = [:]
    private var insertionOrder: [UUID] = []

    init(maxEntries: Int) {
        self.maxEntries = max(1, maxEntries)
    }

    func shardID(for conversationID: UUID) -> String? {
        values[conversationID]
    }

    func store(_ shardID: String, for conversationID: UUID) {
        if values[conversationID] == nil {
            insertionOrder.append(conversationID)
        }
        values[conversationID] = shardID
        trimIfNeeded()
    }

    private func trimIfNeeded() {
        guard values.count > maxEntries else {
            return
        }

        let overflow = values.count - maxEntries
        for conversationID in insertionOrder.prefix(overflow) {
            values[conversationID] = nil
        }
        insertionOrder.removeFirst(min(overflow, insertionOrder.count))
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

    func shardID(for conversationID: UUID) async throws -> String {
        if let entry = try await ConversationDirectoryEntry.find(conversationID, on: db) {
            return entry.shardID
        }
        return SingleShardConversationShardRouter.defaultShardID
    }

    func registerConversation(conversationID: UUID, shardID: String) async throws {
        if let entry = try await ConversationDirectoryEntry.find(conversationID, on: db) {
            entry.shardID = shardID
            try await entry.update(on: db)
            return
        }
        try await ConversationDirectoryEntry(
            conversationID: conversationID,
            shardID: shardID
        ).create(on: db)
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
        memberUserIDs
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
            let directory = DatabaseConversationDirectory(db: db)
            storage[ConversationDirectoryStorageKey.self] = directory
            return directory
        }
        set { storage[ConversationDirectoryStorageKey.self] = newValue }
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
