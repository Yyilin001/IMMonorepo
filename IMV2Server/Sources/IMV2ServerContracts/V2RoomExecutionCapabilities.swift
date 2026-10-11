import Foundation
import IMV2ActorContracts
import IMV2Core

/// A store-bound preparation capability. The captured executor retains the
/// exact store, commands and activation; preparation alone grants no write
/// authority. Concrete persistence handles stay below the application boundary.
public struct V2PreparedRoomSendOperationBatch: Sendable {
    private let operation: @Sendable () async throws -> [V2RoomMessagingResult]

    package init(operation: @escaping @Sendable () async throws -> [V2RoomMessagingResult]) {
        self.operation = operation
    }

    package func execute() async throws -> [V2RoomMessagingResult] {
        try await operation()
    }
}

// Each activation lane receives only the commands it can execute. The concrete
// SQL implementations are assembled by the server activation factory.
package protocol V2RoomMessagingExecuting: Sendable {
    func execute(_ command: V2RoomMessagingCommand) async throws -> V2RoomMessagingResult
    func executeSendOperationBatch(_ commands: [V2MessageSendOperationCommand]) async throws -> [V2RoomMessagingResult]
    func prepareSendOperationBatch(_ commands: [V2MessageSendOperationCommand],
                                   deadline: ContinuousClock.Instant) async throws -> V2PreparedRoomSendOperationBatch
}


package protocol V2RoomAdministrationExecuting: Sendable {
    func executeUser(_ command: V2RoomAdministrationCommand) async throws -> V2RoomAdministrationResult
    func executeTrustedSafety(_ request: V2ActorTrustedSafetyWire,
                              authority: V2ActorTrustedSafetyAuthority) async throws -> V2RoomAdministrationResult
    func execute(_ query: V2RoomAdministrationQuery) async throws -> V2RoomAdministrationResult
}

package protocol V2RoomQueryExecuting: Sendable {
    func log(_ query: V2RoomLogQuery) async throws -> V2RoomLogQueryResult
    func directory(_ query: V2RoomDirectoryQuery) async throws -> V2RoomDirectoryResult
}

package protocol V2RoomReceiptQueryExecuting: Sendable {
    func query(_ query: V2RoomReceiptQuery) async throws -> V2RoomReceiptResult
}

package protocol V2RoomMediaAuthorizationExecuting: Sendable {
    func execute(_ query: V2RoomMediaAuthorizationQuery) async throws -> V2RoomMediaAuthorizationResult
    func executeProfileVisibilityBatch(_ requests: [V2ActorProfileVisibilityBatchWire]) async throws -> [V2RoomMediaAuthorizationResult]
}

/// A complete fenced messaging operation is performed atomically by its store.
package protocol V2RoomMessagingPersisting: Sendable {
    func execute(_ command: V2RoomMessagingCommand) async throws -> V2RoomMessagingResult
    func executeSendOperationBatch(_ commands: [V2MessageSendOperationCommand]) async throws -> [V2RoomMessagingResult]
    func prepareSendOperationBatch(_ commands: [V2MessageSendOperationCommand],
                                   deadline: ContinuousClock.Instant) async throws -> V2PreparedRoomSendOperationBatch
}


package protocol V2RoomAdministrationStoring: Sendable {
    func executeUser(_ command: V2RoomAdministrationCommand) async throws -> V2RoomAdministrationResult
    func executeTrustedSafety(_ request: V2ActorTrustedSafetyWire,
                              authority: V2ActorTrustedSafetyAuthority) async throws -> V2RoomAdministrationResult
    func execute(_ query: V2RoomAdministrationQuery) async throws -> V2RoomAdministrationResult
}

package protocol V2RoomMembershipOperationPersisting: Sendable {
    func admitMembership(_ intent: V2MembershipIntent,
                         snapshot: V2MembershipIdentitySnapshot) async throws -> V2MembershipAdmissionResult
    func submitMembership(_ command: V2MembershipOperationCommand,
                          snapshot: V2MembershipIdentitySnapshot) async throws -> V2MembershipRecoveryResult
    func recoverMembership(_ request: V2MembershipRecoveryRequest) async throws -> V2MembershipRecoveryResult
}

package protocol V2RoomMediaAuthorizationStoring: Sendable {
    func execute(_ query: V2RoomMediaAuthorizationQuery) async throws -> V2RoomMediaAuthorizationResult
    func executeProfileVisibilityBatch(_ requests: [V2ActorProfileVisibilityBatchWire]) async throws -> [V2RoomMediaAuthorizationResult]
}

/// Created from the authenticated service lane, never decoded from command data.
public struct V2ActorTrustedSafetyAuthority: Sendable {
    package let safetyActorUserID: UserID
    package init(safetyActorUserID: UserID) { self.safetyActorUserID = safetyActorUserID }
}

/// An admitted read carries the exact token and both original deadlines.
public struct V2GrantedRoomReadTurn: Sendable {
    public let token: V2RoomActivationToken
    public let actorUserID: UserID
    public let batchDeadline: ContinuousClock.Instant
    public let callDeadline: ContinuousClock.Instant

    package init(token: V2RoomActivationToken, actorUserID: UserID,
         batchDeadline: ContinuousClock.Instant, callDeadline: ContinuousClock.Instant) {
        self.token = token
        self.actorUserID = actorUserID
        self.batchDeadline = batchDeadline
        self.callDeadline = callDeadline
    }
}

public enum V2HostRoomRecoveryBatchError: Error, Equatable, Sendable {
    case busy
    case oversized
    case deadlineExceeded
    case corruptResult
}
