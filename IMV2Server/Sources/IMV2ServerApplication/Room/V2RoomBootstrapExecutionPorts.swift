import IMV2ServerContracts
import Foundation
import IMV2Core

/// Executes a proven direct-room operation against its owner. Receipt lookup,
/// pair locks, authority reads and proof writes remain one store operation.
public protocol V2DirectRoomBootstrapExecuting: Sendable {
    func submitDirectRoomOperation(_ command: V2DirectRoomOperationCommand,
        roomID: RoomID, roomShardID: String, capacityProfile: V2CapacityProfile,
        now: Date) async throws -> V2DirectRoomOperationResult
    func recoverDirectRoomOperation(_ request: V2DirectRoomOperationRecoveryRequest,
        now: Date) async throws -> V2DirectRoomOperationResult
}

/// Staging and final creation retain their existing owner transactions and
/// persisted operation identity in the concrete adapter.
public protocol V2GroupRoomBootstrapExecuting: Sendable {
    func stageControlValidatedAudience(intent: V2GroupRoomCreationIntent,
        page: V2GroupRoomCreationManifestPage, now: Date) async throws
    func createProvenGroup(intent: V2GroupCreationIntent, placement: V2GroupRoomCreationIntent,
        capacityProfile: V2CapacityProfile, now: Date) async throws -> V2GroupCreationOperationResult
}
