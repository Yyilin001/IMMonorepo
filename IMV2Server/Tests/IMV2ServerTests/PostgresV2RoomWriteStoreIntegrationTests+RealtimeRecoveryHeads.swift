import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("one recovery-head snapshot isolates missing and changed room authority")
    func realtimeRecoveryHeadsIsolateUnavailableTopics() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            // This fixture's real shard-admission lease is valid from the
            // seeded business instant to +100 seconds. Room creation must
            // use that original fixture clock; recovery-head reads themselves
            // have no lease-time dependency.
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let opened = try await V2DirectRoomOperationTestFixture(database: database,
                capacityProfile: forwardImportTestProfile(), roomShardID: "room-a",
                roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()),
                    targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1_000) + 60_000)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let valid = V2RealtimeTopic(kind: .roomEvents, id: opened.roomID.rawValue, owner: owner)
            let changed = try V2RealtimeTopic(kind: .roomEvents, id: opened.roomID.rawValue,
                owner: .init(shardID: "room-a", epoch: 1))
            let wrongShard = try V2RealtimeTopic(kind: .roomEvents, id: opened.roomID.rawValue,
                owner: .init(shardID: "room-b", epoch: 0))
            let missing = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString.lowercased(), owner: owner)
            let invalid = V2RealtimeTopic(kind: .roomEvents, id: "invalid-room", owner: owner)
            let topics = [valid, changed, wrongShard, missing, invalid]
            let reader = try PostgresV2RealtimeRoomHeadReader(database: database)
            let values = try await reader.heads(topics: topics)
            #expect(Set(values.keys) == Set(topics))
            #expect(values[changed] == .unavailable(.wrongOwner))
            #expect(values[wrongShard] == .unavailable(.wrongOwner))
            #expect(values[missing] == .unavailable(.wrongOwner))
            #expect(values[invalid] == .unavailable(.invalid))
            guard case .available(let actualHead) = values[valid] else {
                Issue.record("healthy authority lost to an unavailable sibling"); return
            }
            // A second healthy snapshot preserves the same actual room head;
            // unavailable siblings neither mutate it nor fabricate zero rows.
            #expect(try await reader.heads(topics: [valid])[valid] == .available(actualHead))
        }
    }
}
