import Foundation
import SQLKit
import FluentKit
import IMV2Core
@testable import IMV2ServerInfrastructure
@testable import IMV2Server
import IMV2ServerContracts
import IMV2ServerApplication

// Plain fixture databases have no production pool metadata. Capacity is explicit.
extension V2DurableSendOperationOwnerBatcher {
    convenience init(fixtureStore store: PostgresV2MessageSendOperationStore,
        connectionCapacity: Int, capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIDFactory = .init(), now: @escaping @Sendable () -> Date,
        configuration: V2SendOperationSchedulingConfiguration, maximumRetainedBytes: Int) {
        self.init(store: store, configuration: configuration,
            maximumRetainedBytes: maximumRetainedBytes, resourceDemandLimit: connectionCapacity,
            scheduledConnection: { deadline, body in
                try await store.withMessageWriteConnection(deadline: deadline, body)
            }, scheduledExecute: { executor, prepared in
                try await executor.execute(prepared, capacityProfile, identifiers, now)
            })
    }
}

func v2FixtureMessageWriteDatabase(_ database: any Database, capacity: Int) throws -> V2EventLoopBalancedDatabase {
    // The fixture's message budget must not inherit every control-pool slot:
    // fixed workers retain these slots for their entire lifetime.
    return try .init(databases: [database], loanPolicy: .init(maximumConnections: capacity,
        reservedRenewalConnections: 0, maximumQueued: 128, maximumWait: .seconds(10)),
        sessionTimeouts: .default)
}

// Factory tests use the same policy owner and initialization path as production.
extension V2RoomServerOwnerResources {
    func usingFixturePolicyAuthorizations(controlDatabase: (any Database)? = nil, endpoint: String) throws -> Self {
        let control = controlDatabase ?? database
        let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
            dispatcher: .init(database: control, projectionDelivery: V2DiscardingUserShardProjectionDelivery()))
        let policies = V2RoomPolicyAuthorizationService(roomDatabase: database, policyOwners: owners, endpoint: endpoint, maximumRooms: 4_096)
        return try usingPolicyAuthorizations(policies)
    }
}

func v2FixtureRoomPolicyAuthorizations(database: any Database, controlDatabase: (any Database)? = nil, endpoint: String = "fixture") -> V2RoomPolicyAuthorizationService {
    let control = controlDatabase ?? database
    let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: control),
        dispatcher: .init(database: control, projectionDelivery: V2DiscardingUserShardProjectionDelivery()))
    return V2RoomPolicyAuthorizationService(roomDatabase: database, policyOwners: owners,
        endpoint: endpoint, maximumRooms: 4_096)
}

extension V2RoomPolicyAuthorizationService {
    func fixtureSendPreparation(store: PostgresV2MessageSendOperationStore,
        now: @escaping @Sendable () -> Date) -> V2RoomSendPreparation {
        { commands, token, deadline in
            try await self.prepareOwnerBatches(store: store,
                requests: [.init(commands: commands, token: token, deadline: deadline)],
                now: now)[0].get()
        }
    }
}

/// Test composition for direct store calls: installs actual Policy Owner state.
func v2FixtureMessageSendOperationStore(database: any Database, writes: PostgresV2RoomWriteStore,
    clock: @escaping @Sendable () -> Date = Date.init,
    committedMessageObserver: (any V2CommittedMessageBatchObserving)? = nil,
    sendOperationMetrics: V2SendOperationBatchMetrics? = nil) -> PostgresV2MessageSendOperationStore {
    let policies = v2FixtureRoomPolicyAuthorizations(database: database)
    return .init(database: database, writes: writes.usingPolicyAuthorizations(policies), clock: clock,
        committedMessageObserver: committedMessageObserver, sendOperationMetrics: sendOperationMetrics)
}

// A same-database fixture uses the current explicit mute reader contract.
func v2FixturePushWakeStore(database: any Database,
    makeUUID: @escaping @Sendable () -> UUID = UUID.init) -> PostgresV2PushWakeStore {
    .init(database: database, makeUUID: makeUUID, conversationMuted: { room, user, now in
        guard let sql = database as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.user_room_preferences WHERE room_id=\(bind: room) AND user_id=\(bind: user) AND mute_until>\(bind: now)) AS value")
            .first(decoding: V2FixturePushMuteRow.self)?.value == true
    })
}
private struct V2FixturePushMuteRow: Decodable { let value: Bool }

/// Explicit ownership for policy-mutating integration tests, including failure cleanup.
func withFixturePolicyOwners<Value: Sendable>(database: any Database,
    projectionDelivery: any V2UserShardProjectionDelivering,
    _ body: (PostgresV2PolicyOwnerDirectory) async throws -> Value) async throws -> Value {
    let owners = PostgresV2PolicyOwnerDirectory(journal: .init(database: database),
        dispatcher: .init(database: database, projectionDelivery: projectionDelivery))
    do {
        let result = try await body(owners)
        await owners.shutdown()
        return result
    } catch {
        await owners.shutdown()
        throw error
    }
}

/// The current baseline rejects the retired rejection ledger instead of keeping an empty table.
func retiredDirectDenialTableIsAbsent(on sql: any SQLDatabase) async throws -> Bool {
    struct Row: Decodable { let absent: Bool }
    guard let row = try await sql.raw("SELECT to_regclass('im_v2.direct_message_denials') IS NULL AS absent")
        .first(decoding: Row.self) else { return false }
    return row.absent
}
