import IMV2ServerApplication
import FluentKit
import Foundation

extension PostgresV2GroupInvitationControlCommandStore: V2GroupInvitationCommandJournal {}
extension PostgresV2GroupJoinQuotaStore: V2GroupJoinQuotaAuthority {}

extension V2ActorInvitationCoordinator {
    public init(controlDatabase: any Database, room: V2ActorInvitationRoomPort,
                operations: V2GroupInvitationOperationRoomPort,
                secretIssuer: V2GroupInviteSecretIssuer,
                policy: V2GroupInvitationPolicy = .standard,
                makeUUID: @escaping @Sendable () -> UUID = UUID.init,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.init(commands: PostgresV2GroupInvitationControlCommandStore(database: controlDatabase),
            directory: PostgresV2GroupInviteDirectory(database: controlDatabase),
            quota: PostgresV2GroupJoinQuotaStore(database: controlDatabase),
            room: room, operations: operations, secretIssuer: secretIssuer,
            policy: policy, makeUUID: makeUUID, now: now)
    }
}
