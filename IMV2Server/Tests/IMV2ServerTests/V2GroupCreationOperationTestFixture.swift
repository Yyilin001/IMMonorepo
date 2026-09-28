import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server

/// Runs the current control manifest and fixed owner bootstrap against actual
/// stores; no legacy creation coordinator or draft table is reproduced.
struct V2GroupCreationOperationTestFixture: Sendable {
    let store: PostgresV2GroupCreationOperationStore

    init(control: any Database, owner: any Database, shardID: String,
         capacityProfile: V2CapacityProfile, now: @escaping @Sendable () -> Date) throws {
        let executor = try V2RoomBootstrapDomainExecutor(shardID: shardID,
            direct: PostgresV2DirectMessagingStore(database: owner, identityReader: PostgresV2DirectRoomIdentityReader(database: control), projectionDelivery: SuccessfulProjectionDelivery()), group: PostgresV2GroupMessagingStore(database: owner),
            capacityProfile: capacityProfile, now: now)
        let bootstrap = V2ActorCreationBootstrapPort(execute: { command, _ in
            try await executor.execute(command)
        }, stage: { placement, page, _ in
            try await executor.stage(intent: placement, page: page)
        })
        store = PostgresV2GroupCreationOperationStore(database: control,
            selector: try .init(shardIDs: [shardID]), bootstrap: bootstrap, capacityProfile: capacityProfile)
    }

    struct CreatedIdentity: Sendable {
        let receipt: V2GroupCreationReceipt
        let roomID: RoomID
        let title: String
        let capacityClass: V2GroupCapacityClass
        let memberCount: Int
    }

    func create(intent: V2GroupCreationIntent, canonicalMembers: [UserID], now: Date) async throws -> CreatedIdentity {
        guard intent.audienceDigest == (try V2GroupCreationAudience.digest(canonicalMembers)) else {
            throw V2GroupCreationValidationError.invalidIntent
        }
        _ = try await store.begin(intent, now: now)
        let size = V2GroupCreationAudience.maximumPageMembers
        for offset in stride(from: 0, to: canonicalMembers.count, by: size) {
            _ = try await store.append(.init(intent: intent, offset: offset,
                memberUserIDs: Array(canonicalMembers[offset..<min(offset+size,canonicalMembers.count)])), now: now)
        }
        var result = try await store.finalize(intent, now: now, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        // Each advancement copies at most one owner manifest page.
        for _ in 0...(canonicalMembers.count/size+2) {
            if case .receipt(let receipt) = result, case .created(let room,let title,let capacity,let count) = receipt.outcome {
                guard receipt.validates(intent: intent) else { throw V2GroupCreationValidationError.invalidReceipt }
                return .init(receipt: receipt, roomID: room, title: title, capacityClass: capacity, memberCount: count)
            }
            result = try await store.recover(.init(intent: intent, action: .query), now: now)
        }
        throw V2GroupMessagingStoreError.corruptPersistenceState
    }
}
