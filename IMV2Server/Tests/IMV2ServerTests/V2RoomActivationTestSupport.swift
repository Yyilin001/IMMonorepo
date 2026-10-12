@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

/// Runs a database business operation in the shared native Host's room lane.
/// The final caller awaits physical Host drain and control-plane retirement.
func withRoomActivation<Value: Sendable>(
    database: any Database,
    roomID: RoomID,
    shardID: String = "room-a",
    epoch: Int64 = 0,
    _ body: @escaping @Sendable (V2RoomActivationToken) async throws -> Value
) async throws -> Value {
    let owner = try V2RoomDataOwner(shardID: shardID, epoch: epoch)
    return try await V2DatabaseRoomActorTestRuntime.shared.execute(roomID: roomID, owner: owner, body)
}

/// Holds actual native room lanes in canonical order while a bounded owner
/// batch executes. Canonical ordering prevents opposite room pairs from
/// acquiring their lanes in reverse order.
func withRoomActivations<Value: Sendable>(
    database: any Database,
    roomIDs: [RoomID],
    shardID: String = "room-a",
    epoch: Int64 = 0,
    _ body: @escaping @Sendable ([V2RoomActivationToken]) async throws -> Value
) async throws -> Value {
    guard !roomIDs.isEmpty, roomIDs.count <= 128, Set(roomIDs).count == roomIDs.count else {
        throw V2RoomCallFailure.notAccepted(.invalidRequest)
    }
    let owner = try V2RoomDataOwner(shardID: shardID, epoch: epoch)
    return try await withRoomActivations(database: database,
        owners: Dictionary(uniqueKeysWithValues: roomIDs.map { ($0, owner) }), body)
}

/// A data-owner migration can change one member of a pair independently.
/// The native lanes remain canonically ordered across all selected rooms.
func withRoomActivations<Value: Sendable>(
    database: any Database,
    owners: [RoomID: V2RoomDataOwner],
    _ body: @escaping @Sendable ([V2RoomActivationToken]) async throws -> Value
) async throws -> Value {
    guard !owners.isEmpty, owners.count <= 128 else {
        throw V2RoomCallFailure.notAccepted(.invalidRequest)
    }
    let rooms = owners.keys.sorted { $0.rawValue < $1.rawValue }
    @Sendable func enter(_ index: Int, _ tokens: [V2RoomActivationToken]) async throws -> Value {
        if index == rooms.count { return try await body(tokens) }
        let room = rooms[index], owner = owners[room]!
        return try await withRoomActivation(database: database, roomID: room,
                                           shardID: owner.shardID, epoch: owner.epoch) { token in
            try await enter(index + 1, tokens + [token])
        }
    }
    return try await enter(0, [])
}

/// Media authorization retains a native pin through actual SQL settlement.
func withRoomActivationLifetime<Value: Sendable>(
    database: any Database,
    roomID: RoomID,
    shardID: String = "room-a",
    epoch: Int64 = 0,
    _ body: @escaping @Sendable (V2RoomActivationToken, V2RoomActivationLifetime) async throws -> Value
) async throws -> Value {
    let owner = try V2RoomDataOwner(shardID: shardID, epoch: epoch)
    return try await V2DatabaseRoomActorTestRuntime.shared.executeWithLifetime(roomID: roomID, owner: owner, body)
}

/// Runs the activation-fenced room bookkeeping turn that production room
/// actors use for room-owned operation ledgers and review jobs. Control-plane
/// housekeeping never deletes those rows, so integration tests that age them
/// must purge through this path.
func purgeRoomBookkeeping(
    database: any Database,
    roomID: UUID,
    shardID: String = "room-a",
    now: Date,
    retention: TimeInterval = 7 * 86_400,
    idempotencyRetention: TimeInterval = V2IdempotencyPolicy.minimumServerRetention
) async throws -> V2ActorRoomBookkeepingPurgeResultWire {
    try await withRoomActivation(database: database, roomID: .init(uuid: roomID), shardID: shardID) { token in
        try await PostgresV2RoomBookkeepingStore(database: database).purge(
            token: token, now: now, retention: retention,
            idempotencyRetention: idempotencyRetention, rowLimit: 1_000)
    }
}

/// Source-room forward command transport for delivery-worker tests. Like
/// RoomRef in the gateway, each command runs the production room forward
/// executor under an activation of the source room.
func forwardSourceCommand(
    database: any Database,
    shardID: String = "room-a",
    now: @escaping @Sendable () -> Date
) -> @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult {
    { command, _ in
        try await withRoomActivation(database: database, roomID: command.roomID, shardID: shardID) { token in
            try await V2RoomForwardDomainExecutor(database: database, token: token,
                importExport: { _, _, _ in throw V2RoomCallFailure.notAccepted(.invalidRequest) },
                now: now).execute(command)
        }
    }
}

/// A forward source transport for delivery tests whose target never returns
/// a terminal receipt; any source command is a test failure.
let forwardSourceCommandUnexpected: @Sendable (V2RoomForwardCommand, ContinuousClock.Instant) async throws -> V2RoomForwardResult = { _, _ in
    throw V2RoomCallFailure.notAccepted(.invalidRequest)
}

/// Room port for V2ActorInvitationCoordinator tests. Like RoomRef, each
/// query runs the production room invitation executor under an
/// activation of that room on its owner database.
func invitationRoomPort(
    control: any Database,
    owner: @escaping @Sendable (RoomID) throws -> (database: any Database, shardID: String, epoch: Int64),
    capacityProfile: V2CapacityProfile,
    now: @escaping @Sendable () -> Date
) -> V2ActorInvitationRoomPort {
    let identities = PostgresV2GroupInvitationIdentityReader(database: control)
    @Sendable func run(
        _ roomID: RoomID,
        _ body: @escaping @Sendable (V2RoomInvitationDomainExecutor) async throws -> V2RoomInvitationResult
    ) async throws -> V2RoomInvitationResult {
        let location = try owner(roomID)
        return try await withRoomActivation(database: location.database, roomID: roomID,
                                            shardID: location.shardID, epoch: location.epoch) { token in
            try await body(V2RoomInvitationDomainExecutor(database: location.database, token: token,
                identities: identities, capacityProfile: capacityProfile, now: now))
        }
    }
    return .init(query: { query, _ in try await run(query.roomID) { try await $0.execute(query) } })
}

/// Single-owner form of ``invitationRoomPort(control:owner:capacityProfile:now:)``.
func invitationRoomPort(
    control: any Database,
    owner: any Database,
    shardID: String = "room-a",
    epoch: Int64 = 0,
    capacityProfile: V2CapacityProfile,
    now: @escaping @Sendable () -> Date
) -> V2ActorInvitationRoomPort {
    invitationRoomPort(control: control, owner: { _ in (owner, shardID, epoch) },
                       capacityProfile: capacityProfile, now: now)
}

/// Typed owner operations use the same activation-fenced store as production;
/// no retired command execution or local control-table mirror is involved.
func invitationOperationPort(
    control: any Database,
    owner: @escaping @Sendable (RoomID) throws -> (database: any Database, shardID: String, epoch: Int64),
    issuer: V2GroupInviteSecretIssuer,
    policy: V2GroupInvitationPolicy = .standard,
    capacityProfile: V2CapacityProfile,
    now: @escaping @Sendable () -> Date
) -> V2GroupInvitationOperationRoomPort {
    let identities = PostgresV2GroupInvitationIdentityReader(database: control)
    @Sendable func run<Value: Sendable>(roomID: RoomID, inviteID: GroupInviteID?, deadline: ContinuousClock.Instant,
        _ body: @escaping @Sendable (PostgresV2GroupInvitationOperationStore) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let location = try owner(roomID)
        return try await withRoomActivation(database: location.database, roomID: roomID,
            shardID: location.shardID, epoch: location.epoch) { token in
            guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            return try await body(PostgresV2GroupInvitationOperationStore(database: location.database, activationToken: token,
                identities: identities, issuer: issuer, policy: policy, capacity: capacityProfile, inviteID: inviteID))
        }
    }
    @Sendable func invite(_ intent: V2GroupInvitationOperationIntent) -> GroupInviteID? {
        switch intent.action { case .submit(let id, _, _), .revoke(let id, _): id; default: nil }
    }
    return .init(baseline: { query, deadline in
        try await run(roomID: query.roomID, inviteID: nil, deadline: deadline) { try await $0.baseline(roomID: query.roomID, actorUserID: query.actorUserID) }
    }, admit: { intent, deadline in
        try await run(roomID: intent.roomID, inviteID: invite(intent), deadline: deadline) { try await $0.admit(intent, now: now()) }
    }, submit: { request, deadline in
        try await run(roomID: request.command.intent.roomID, inviteID: invite(request.command.intent), deadline: deadline) { try await $0.submit(request, now: now()) }
    }, recover: { request, deadline in
        try await run(roomID: request.intent.roomID, inviteID: invite(request.intent), deadline: deadline) { try await $0.recover(request, now: now()) }
    })
}

func invitationOperationPort(
    control: any Database,
    owner: any Database,
    shardID: String = "room-a",
    epoch: Int64 = 0,
    issuer: V2GroupInviteSecretIssuer,
    policy: V2GroupInvitationPolicy = .standard,
    capacityProfile: V2CapacityProfile,
    now: @escaping @Sendable () -> Date
) -> V2GroupInvitationOperationRoomPort {
    invitationOperationPort(control: control, owner: { _ in (owner, shardID, epoch) }, issuer: issuer,
        policy: policy, capacityProfile: capacityProfile, now: now)
}

/// A generous deadline for coordinator calls whose timing is not under test.
func invitationTestDeadline() -> ContinuousClock.Instant { .now + .seconds(30) }

/// Test-controlled owner availability and epoch for an invitation room port,
/// standing in for a RoomRef whose owner is unreachable or has moved.
final class InvitationOwnerSwitch: Sendable {
    private let state: Mutex<(available: Bool, epoch: Int64)>
    init(epoch: Int64 = 0) { state = Mutex((true, epoch)) }
    func set(available: Bool = true, epoch: Int64) { state.withLock { $0 = (available, epoch) } }
    /// Throws like an unavailable room call when the owner is switched off.
    func current() throws -> Int64 {
        let value = state.withLock { $0 }
        guard value.available else { throw V2RoomCallFailure.notAccepted(.unavailable) }
        return value.epoch
    }
}
