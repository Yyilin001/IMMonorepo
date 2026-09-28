import FluentKit
import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

/// Executes the production owner transaction with explicit original identity,
/// placement and deadline. It neither recreates the retired routing stack nor
/// treats a permanent receipt as current room authorization.
struct V2DirectRoomOperationTestFixture: Sendable {
    let store: PostgresV2DirectMessagingStore
    let capacityProfile: V2CapacityProfile
    let roomShardID: String
    let roomID: RoomID?
    let now: @Sendable () -> Date

    init(database: any Database, capacityProfile: V2CapacityProfile,
         roomShardID: String, roomID: RoomID? = nil,
         now: @escaping @Sendable () -> Date) {
        self.store = PostgresV2DirectMessagingStore(database: database, identityReader: PostgresV2DirectRoomIdentityReader(database: database), projectionDelivery: SuccessfulProjectionDelivery())
        self.capacityProfile = capacityProfile
        self.roomShardID = roomShardID
        self.roomID = roomID
        self.now = now
    }

    init(store: PostgresV2DirectMessagingStore, capacityProfile: V2CapacityProfile,
         roomShardID: String, roomID: RoomID? = nil,
         now: @escaping @Sendable () -> Date) {
        self.store = store; self.capacityProfile = capacityProfile
        self.roomShardID = roomShardID; self.roomID = roomID; self.now = now
    }

    struct OpenedIdentity: Sendable {
        let receipt: V2DirectRoomOperationReceipt
        let roomID: RoomID
        let actorUserID: UserID
        let targetUserID: UserID
        let createdAt: Date
    }

    static func deadline(_ date: Date) throws -> UInt64 {
        guard let ms = UInt64(exactly: try v2GatewayMilliseconds(date)), ms <= UInt64(Int64.max)-600_000 else {
            throw V2DirectMessagingStoreError.corruptPersistenceState
        }
        return ms + 600_000
    }

    func openedIdentity(actorUserID: UserID, operationID: DirectRoomOperationID,
                        targetUserID: UserID, firstSubmissionDeadlineMilliseconds: UInt64) async throws -> OpenedIdentity {
        let receipt = try await openedReceipt(actorUserID: actorUserID, operationID: operationID,
            targetUserID: targetUserID, firstSubmissionDeadlineMilliseconds: firstSubmissionDeadlineMilliseconds)
        guard case .opened(let room, let ms) = receipt.outcome else { throw V2DirectMessagingStoreError.corruptPersistenceState }
        return .init(receipt: receipt, roomID: room, actorUserID: actorUserID, targetUserID: targetUserID,
            createdAt: Date(timeIntervalSince1970: Double(ms)/1_000))
    }

    func submit(actorUserID: UserID, operationID: DirectRoomOperationID,
                targetUserID: UserID, firstSubmissionDeadlineMilliseconds: UInt64) async throws -> V2DirectRoomOperationResult {
        let command = try V2DirectRoomOperationCommand(actorUserID: actorUserID,
            operationID: operationID, targetUserID: targetUserID,
            firstSubmissionDeadlineMilliseconds: firstSubmissionDeadlineMilliseconds)
        return try await store.submitDirectRoomOperation(command, roomID: roomID ?? .init(uuid: operationID.uuidValue!), roomShardID: roomShardID,
                capacityProfile: capacityProfile, now: now())
    }

    func openedReceipt(actorUserID: UserID, operationID: DirectRoomOperationID,
                       targetUserID: UserID, firstSubmissionDeadlineMilliseconds: UInt64) async throws -> V2DirectRoomOperationReceipt {
        let result = try await submit(actorUserID: actorUserID, operationID: operationID,
            targetUserID: targetUserID, firstSubmissionDeadlineMilliseconds: firstSubmissionDeadlineMilliseconds)
        guard case .receipt(let receipt) = result, case .opened = receipt.outcome else {
            Issue.record("Expected the original bound direct-room opened receipt")
            throw V2DirectMessagingStoreError.corruptPersistenceState
        }
        return receipt
    }
}
