import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import SQLKit

/// A physical room owner's bounded activation registry.
/// Restored memory registries use the activation boundary's validated snapshot.
/// Cold factories validate the token and read participants themselves. No idle
/// eviction is permitted: retirement joins all real work before capacity frees.
actor PostgresV2RoomPolicyAuthorizationDirectory {
    typealias Factory = @Sendable (V2RoomActivationToken) async throws -> PostgresV2RoomPolicyAuthorizationRegistry
    private struct Entry {
        let id: UUID
        let token: V2RoomActivationToken
        let creation: Task<PostgresV2RoomPolicyAuthorizationRegistry, any Error>
        var retirement: Task<Void, Never>?
        var sealed = false
    }
    nonisolated let endpoint: String
    private let maximumRooms: Int
    private let maximumCreations: Int
    private let factory: Factory
    private let initializedFactory: (@Sendable (V2RoomSendInitialization) throws -> PostgresV2RoomPolicyAuthorizationRegistry)?
    private var entries: [RoomID: Entry] = [:]
    private var creations = 0
    private var closing: Task<Void, Never>?
    private var closed = false

    init(endpoint: String, maximumRooms: Int, maximumCreations: Int = 16,
         factory: @escaping Factory,
         initializedFactory: (@Sendable (V2RoomSendInitialization) throws -> PostgresV2RoomPolicyAuthorizationRegistry)? = nil) {
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
        precondition(maximumRooms > 0 && maximumCreations > 0)
        self.endpoint = endpoint; self.maximumRooms = maximumRooms
        self.maximumCreations = maximumCreations
        self.factory = factory; self.initializedFactory = initializedFactory
    }

    /// Current facts require no room registration or revocation fallback.
    /// Cold creation validates the durable data owner before reading participants.
    init(database: any Database, endpoint: String, maximumRooms: Int,
         maximumCreations: Int = 16,
         databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
         currentLoader: @escaping @Sendable (V2RoomActivationToken, UUID, UUID?, Bool) async throws -> V2CurrentRoomPolicySnapshot) {
        let initializedFactory: @Sendable (V2RoomSendInitialization) throws -> PostgresV2RoomPolicyAuthorizationRegistry = { initialization in
            let token = initialization.token
            if initialization.kind == "direct", let state = initialization.directState {
                return .init(activation: token, participants: (state.lower, state.higher), endpoint: endpoint,
                    currentLoader: { sender, recipient in
                        let replied = recipient.map { user in
                            user == state.lower ? state.lowerReplied : (user == state.higher && state.higherReplied)
                        } ?? false
                        return try await currentLoader(token, sender, recipient, replied)
                    })
            }
            guard initialization.kind == "group" else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
            return .init(activation: token, endpoint: endpoint,
                currentLoader: { sender, recipient in try await currentLoader(token, sender, recipient, false) })
        }
        self.init(endpoint: endpoint, maximumRooms: maximumRooms, maximumCreations: maximumCreations,
            factory: { token in
                try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission, workClass: .sync,
                    callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline()) {
                    try await v2WithRoomScopedTransaction(database: database) { transaction in
                        guard let sql = transaction as? any SQLDatabase, let room = token.roomID.uuidValue else {
                            throw V2PolicyAuthorizationLifecycleError.invalidRequest
                        }
                        try await v2RequireRoomActivation(token: token, sql: sql)
                        guard let kind = try await sql.raw("SELECT room_kind FROM im_v2.rooms WHERE room_id=\(bind: room) FOR SHARE").first(decoding: RoomKind.self) else {
                            throw V2PolicyAuthorizationLifecycleError.invalidTarget
                        }
                        if kind.room_kind == "group" {
                            return try initializedFactory(.init(token: token, kind: "group", directState: nil))
                        }
                        guard kind.room_kind == "direct",
                              let pair = try await sql.raw("""
                                SELECT lower_user_id, higher_user_id FROM im_v2.direct_room_pairs
                                WHERE room_id=\(bind: room) FOR SHARE
                                """).first(decoding: Participants.self) else {
                            throw V2PolicyAuthorizationLifecycleError.invalidTarget
                        }
                        return .init(activation: token,
                            participants: (pair.lower_user_id, pair.higher_user_id), endpoint: endpoint,
                            currentLoader: { sender, recipient in try await currentLoader(token, sender, recipient, false) })
                    }
                }
            },
            initializedFactory: initializedFactory)
    }

    func install(_ initialization: V2RoomSendInitialization) throws {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let token = initialization.token
        if let existing = entries[token.roomID] {
            guard existing.token == token else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            guard !existing.sealed else { throw V2PolicyAuthorizationLifecycleError.closed }
            return
        }
        guard entries.count < maximumRooms, let initializedFactory else {
            throw V2PolicyAuthorizationLifecycleError.busy
        }
        let registry = try initializedFactory(initialization)
        entries[token.roomID] = .init(id: UUID(), token: token, creation: Task { registry })
    }

    func registry(token: V2RoomActivationToken) async throws -> PostgresV2RoomPolicyAuthorizationRegistry {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let entry: Entry
        if let existing = entries[token.roomID] {
            guard existing.token == token else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            guard !existing.sealed else { throw V2PolicyAuthorizationLifecycleError.closed }
            entry = existing
        } else {
            guard entries.count < maximumRooms, creations < maximumCreations else {
                throw V2PolicyAuthorizationLifecycleError.busy
            }
            let id = UUID(), factory = factory, endpoint = endpoint
            let deadline = V2RoomSQLDeadline.boundedTransactionDeadline()
            guard deadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            let task = Task.detached {
                let result: Result<PostgresV2RoomPolicyAuthorizationRegistry, any Error>
                do {
                    let registry = try await V2RoomSQLDeadline.withDeadline(deadline) { try await factory(token) }
                    guard registry.activation == token, registry.endpoint == endpoint else {
                        await registry.shutdown()
                        throw V2PolicyAuthorizationLifecycleError.identityConflict
                    }
                    result = .success(registry)
                } catch { result = .failure(error) }
                await self.creationFinished(room: token.roomID, id: id, failed: result.isFailure)
                return try result.get()
            }
            entry = .init(id: id, token: token, creation: task)
            entries[token.roomID] = entry
            creations += 1
        }
        let registry = try await entry.creation.value
        try Task.checkCancellation()
        guard !closed, entries[token.roomID]?.id == entry.id,
              entries[token.roomID]?.sealed == false else { throw V2PolicyAuthorizationLifecycleError.closed }
        return registry
    }

    func retire(token: V2RoomActivationToken) async {
        guard let entry = entries[token.roomID], entry.token == token else { return }
        if let retirement = entry.retirement { return await retirement.value }
        let task = Task.detached {
            if case .success(let registry) = await entry.creation.result { await registry.shutdown() }
        }
        entries[token.roomID]?.sealed = true
        entries[token.roomID]?.retirement = task
        await task.value
        if entries[token.roomID]?.id == entry.id { entries[token.roomID] = nil }
    }

    func shutdown() async {
        if let closing { return await closing.value }
        closed = true
        let tokens = entries.values.map(\.token)
        let task = Task.detached {
            for token in tokens { await self.retire(token: token) }
        }
        closing = task
        await task.value
    }

    func pressure() -> (closed: Bool, rooms: Int, creations: Int, retiring: Int) {
        (closed, entries.count, creations, entries.values.filter(\.sealed).count)
    }

    private func creationFinished(room: RoomID, id: UUID, failed: Bool) {
        creations -= 1
        if failed, let entry = entries[room], entry.id == id, !entry.sealed { entries[room] = nil }
    }
    private struct RoomKind: Decodable { let room_kind: String }
    private struct Participants: Decodable { let lower_user_id: UUID; let higher_user_id: UUID }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
