import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import SQLKit

/// A physical room owner's bounded activation registry and revocation endpoint.
/// Restored memory registries use the activation boundary's validated snapshot.
/// Compatibility factories validate the token and read participants themselves. No idle
/// eviction is permitted: retirement joins all real work before capacity frees.
actor PostgresV2RoomPolicyAuthorizationDirectory {
    typealias Factory = @Sendable (V2RoomActivationToken) async throws -> PostgresV2RoomPolicyAuthorizationRegistry
    typealias Revoker = @Sendable (V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof
    private struct Entry {
        let id: UUID
        let token: V2RoomActivationToken
        let creation: Task<PostgresV2RoomPolicyAuthorizationRegistry, any Error>
        var retirement: Task<Void, any Error>?
        var sealed = false
    }
    private struct Revocation {
        let holder: V2PolicyAuthorizationHolder
        let task: Task<V2PolicyAuthorizationRevocationProof, any Error>
    }
    nonisolated let endpoint: String
    private let maximumRooms: Int
    private let maximumCreations: Int
    private let maximumRevocations: Int
    private let factory: Factory
    private let initializedFactory: (@Sendable (V2RoomSendInitialization) throws -> PostgresV2RoomPolicyAuthorizationRegistry)?
    private let fallback: Revoker
    private var entries: [RoomID: Entry] = [:]
    private var creations = 0
    private var revocations: [UUID: Revocation] = [:]
    private var closing: Task<Void, any Error>?
    private var closed = false

    init(endpoint: String, maximumRooms: Int, maximumCreations: Int = 16, maximumRevocations: Int = 32,
         factory: @escaping Factory, fallback: @escaping Revoker,
         initializedFactory: (@Sendable (V2RoomSendInitialization) throws -> PostgresV2RoomPolicyAuthorizationRegistry)? = nil) {
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
        precondition(maximumRooms > 0 && maximumCreations > 0 && maximumRevocations > 0)
        self.endpoint = endpoint; self.maximumRooms = maximumRooms
        self.maximumCreations = maximumCreations; self.maximumRevocations = maximumRevocations
        self.factory = factory; self.fallback = fallback; self.initializedFactory = initializedFactory
    }

    /// Production construction reads participants while holding the complete
    /// activation fence. Registry recreation must never trust a delayed token.
    init(database: any Database, endpoint: String, maximumRooms: Int,
         maximumCreations: Int = 16, maximumRevocations: Int = 32,
         databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
         currentLoader: (@Sendable (V2RoomActivationToken, UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot)? = nil,
         loader: @escaping @Sendable (V2RoomActivationToken, V2DirectSendControlPair, UUID, UUID) async throws -> V2RegisteredDirectPolicySnapshot,
         accountLoader: (@Sendable (V2RoomActivationToken, UUID, UUID, UUID) async throws -> V2RegisteredAccountPolicySnapshot)? = nil) {
        let fence = PostgresV2RoomPolicyLeaseFence(database: database, databaseWorkAdmission: databaseWorkAdmission)
        let initializedFactory: (@Sendable (V2RoomSendInitialization) throws -> PostgresV2RoomPolicyAuthorizationRegistry)?
        if let current = currentLoader {
            initializedFactory = { initialization in
                let token = initialization.token
                if initialization.kind == "direct", let state = initialization.directState {
                    return PostgresV2RoomPolicyAuthorizationRegistry(activation: token,
                        participants: (state.lower, state.higher), endpoint: endpoint, fence: fence,
                        currentLoader: { sender, recipient in try await current(token, sender, recipient) })
                }
                guard initialization.kind == "group", let accountLoader else {
                    throw V2PolicyAuthorizationLifecycleError.invalidTarget
                }
                return PostgresV2RoomPolicyAuthorizationRegistry(activation: token, endpoint: endpoint, fence: fence,
                    currentLoader: { sender, recipient in try await current(token, sender, recipient) },
                    accountLoader: { sender, registration, activation in
                        try await accountLoader(token, sender, registration, activation)
                    })
            }
        } else { initializedFactory = nil }
        self.init(endpoint: endpoint, maximumRooms: maximumRooms, maximumCreations: maximumCreations,
            maximumRevocations: maximumRevocations, factory: { token in
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
                            guard let accountLoader else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                            let loadCurrentAccount: (@Sendable (UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot)?
                            if let currentLoader { loadCurrentAccount = { sender, recipient in try await currentLoader(token, sender, recipient) } }
                            else { loadCurrentAccount = nil }
                            return PostgresV2RoomPolicyAuthorizationRegistry(activation: token,
                                endpoint: endpoint, fence: fence,
                                currentLoader: loadCurrentAccount,
                                accountLoader: { sender, registration, activation in
                                    try await accountLoader(token, sender, registration, activation)
                                })
                        }
                        guard kind.room_kind == "direct" else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                        guard let pair = try await sql.raw("""
                            SELECT lower_user_id, higher_user_id FROM im_v2.direct_room_pairs
                            WHERE room_id=\(bind: room) FOR SHARE
                            """).first(decoding: Participants.self) else {
                            throw V2PolicyAuthorizationLifecycleError.invalidTarget
                        }
                        if let currentLoader {
                            return PostgresV2RoomPolicyAuthorizationRegistry(activation: token,
                                participants: (pair.lower_user_id, pair.higher_user_id), endpoint: endpoint, fence: fence,
                                currentLoader: { sender, recipient in try await currentLoader(token, sender, recipient) })
                        }
                        return PostgresV2RoomPolicyAuthorizationRegistry(activation: token,
                            participants: (pair.lower_user_id, pair.higher_user_id), endpoint: endpoint, fence: fence,
                            loader: { pair, registration, activation in try await loader(token, pair, registration, activation) })
                    }
                }
            }, fallback: { try await fence.revoke($0) }, initializedFactory: initializedFactory)
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
                        try await registry.shutdown()
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

    func retire(token: V2RoomActivationToken) async throws {
        guard let entry = entries[token.roomID], entry.token == token else { return }
        if let retirement = entry.retirement { return try await retirement.value }
        let task = Task.detached {
            if case .success(let registry) = await entry.creation.result { try await registry.shutdown() }
        }
        entries[token.roomID]?.sealed = true
        entries[token.roomID]?.retirement = task
        do {
            try await task.value
            if entries[token.roomID]?.id == entry.id { entries[token.roomID] = nil }
        } catch {
            // Keep the failed retirement sealed. A later retirement retry may
            // repeat durable cleanup, while registry() must remain closed.
            entries[token.roomID]?.retirement = nil
            throw error
        }
    }

    func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        try Task.checkCancellation()
        guard holder.endpoint == endpoint else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        if let existing = revocations[holder.registrationID] {
            guard existing.holder == holder else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
            return try await existing.task.value
        }
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard revocations.count < maximumRevocations else { throw V2PolicyAuthorizationLifecycleError.busy }
        let entry = entries[.init(uuid: holder.roomID)], fallback = fallback
        let task = Task.detached {
            let result: Result<V2PolicyAuthorizationRevocationProof, any Error>
            do {
                let proof: V2PolicyAuthorizationRevocationProof
                if let entry, case .success(let registry) = await entry.creation.result {
                    do { proof = try await registry.revoke(holder) }
                    catch V2PolicyAuthorizationLifecycleError.closed { proof = try await fallback(holder) }
                } else { proof = try await fallback(holder) }
                guard proof.holder == holder else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
                result = .success(proof)
            } catch { result = .failure(error) }
            await self.revocationFinished(holder.registrationID)
            return try result.get()
        }
        revocations[holder.registrationID] = .init(holder: holder, task: task)
        return try await task.value
    }

    func shutdown() async throws {
        if let closing { return try await closing.value }
        closed = true
        let tokens = entries.values.map(\.token), work = revocations.values.map(\.task)
        let task = Task.detached {
            var failure: (any Error)?
            for token in tokens {
                do { try await self.retire(token: token) } catch { if failure == nil { failure = error } }
            }
            for task in work {
                if case .failure(let error) = await task.result, failure == nil { failure = error }
            }
            if let failure { throw failure }
        }
        closing = task
        do { try await task.value } catch { closing = nil; throw error }
    }

    func pressure() -> (closed: Bool, rooms: Int, creations: Int, retiring: Int, revocations: Int) {
        (closed, entries.count, creations, entries.values.filter(\.sealed).count, revocations.count)
    }

    private func creationFinished(room: RoomID, id: UUID, failed: Bool) {
        creations -= 1
        if failed, let entry = entries[room], entry.id == id, !entry.sealed { entries[room] = nil }
    }
    private func revocationFinished(_ id: UUID) { revocations[id] = nil }
    private struct RoomKind: Decodable { let room_kind: String }
    private struct Participants: Decodable { let lower_user_id: UUID; let higher_user_id: UUID }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { true } else { false } }
}
