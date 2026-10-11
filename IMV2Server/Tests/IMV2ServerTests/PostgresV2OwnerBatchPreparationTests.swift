@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("cross-room preparation keeps full operation keys and isolates replay, fresh and control identity conflict")
    func durableOwnerPreparationUsesFullRoomKeys() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            var rooms: [RoomID] = []
            for recipient in [memberTwoUUID, memberThreeUUID] {
                let opened = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                    roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                        actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: recipient),
                        firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
                rooms.append(opened.roomID)
            }
            let roomIDs = rooms
            @Sendable func command(room: RoomID, operation: ClientMessageID, text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: room, senderUserID: senderID, clientMessageID: operation,
                    text: text, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            let operation = ClientMessageID(uuid: UUID())
            let first = try command(room: roomIDs[0], operation: operation, text: "room A same UUID")
            let second = try command(room: roomIDs[1], operation: operation, text: "room B same UUID")
            let policies = v2FixtureRoomPolicyAuthorizations(database: database)
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database).usingPolicyAuthorizations(policies), clock: { now })
            try await withRoomActivation(database: database, roomID: roomIDs[0]) { firstToken in
                try await withRoomActivation(database: database, roomID: roomIDs[1]) { secondToken in
                    let deadline = ContinuousClock.now + .seconds(30)
                    let prepared = try await policies.prepareOwnerBatches(store: store, requests: [
                        .init(commands: [first], token: firstToken, deadline: deadline),
                        .init(commands: [second], token: secondToken, deadline: deadline)
                    ], now: { now })
                    let handles = try prepared.map { try $0.get() }
                    let accepted = try await store.executeIndependentRoomTurns(handles, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    for value in accepted {
                        guard case .sendOperation(.receipt(let receipt))? = try value.get().first,
                              case .accepted = receipt.outcome else { Issue.record("both room-scoped UUIDs must accept"); return }
                    }
                    let conflictOperation = ClientMessageID(uuid: UUID())
                    let original = try command(room: roomIDs[1], operation: conflictOperation, text: "committed immutable original")
                    // The durable success identity is authoritative across rooms.
                    // Preparation itself must not persist an authorization obligation.
                    let originalPrepared = try await policies.prepareOwnerBatches(store: store, requests: [
                        .init(commands: [original], token: secondToken, deadline: deadline)
                    ], now: { now })
                    let originalResults = try await store.executeIndependentRoomTurns(
                        try originalPrepared.map { try $0.get() }, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    guard case .sendOperation(.receipt(let originalReceipt))? = try originalResults[0].get().first,
                          case .accepted = originalReceipt.outcome else {
                        Issue.record("original identity must commit before conflicting replay"); return
                    }
                    let changed = try command(room: roomIDs[1], operation: conflictOperation, text: "conflicting immutable content")
                    let healthy = try command(room: roomIDs[1], operation: .init(uuid: UUID()), text: "healthy fresh neighbour")
                    let mixed = try await policies.prepareOwnerBatches(store: store, requests: [
                        .init(commands: [first], token: firstToken, deadline: deadline),
                        .init(commands: [healthy], token: secondToken, deadline: deadline),
                        .init(commands: [changed], token: secondToken, deadline: deadline),
                        .init(commands: [first], token: secondToken, deadline: deadline)
                    ], now: { now })
                    #expect(mixed.count == 4)
                    guard case .failure(let invalid) = mixed[3],
                          invalid as? V2RoomCallFailure == .notAccepted(.invalidRequest) else {
                        Issue.record("one invalid room/token binding must be isolated"); return
                    }
                    let mixedHandles = try mixed.prefix(3).map { try $0.get() }
                    let results = try await store.executeIndependentRoomTurns(mixedHandles, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                    for index in [0, 1] {
                        guard case .sendOperation(.receipt(let receipt))? = try results[index].get().first,
                              case .accepted = receipt.outcome else { Issue.record("replay and healthy item must survive conflict"); return }
                    }
                    guard case .sendOperation(.fingerprintConflict)? = try results[2].get().first else {
                        Issue.record("the committed success fingerprint must remain authoritative"); return
                    }
                    let facts = try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM im_v2.messages").first(decoding: OwnerPreparationCount.self))
                    #expect(facts.value == 4)
                    let obligations = try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM pg_catalog.pg_class WHERE oid=to_regclass('im_v2.direct_authorization_intents')").first(decoding: OwnerPreparationCount.self))
                    #expect(obligations.value == 0)
                }
            }
        }
    }
}
private struct OwnerPreparationCount: Decodable { let value: Int64 }
