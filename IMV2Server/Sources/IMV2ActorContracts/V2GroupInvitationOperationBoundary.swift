import IMV2Core

public struct V2GroupInvitationOperationBaselineQuery: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let actorUserID: UserID
    public init(roomID: RoomID, actorUserID: UserID) { self.roomID = roomID; self.actorUserID = actorUserID }
}
/// Only the authenticated account coordinator can supply a globally reserved
/// join slot. The public HTTP payload has no field for this authority.
public struct V2GroupInvitationExecutionRequest: Codable, Equatable, Sendable {
    public let command: V2GroupInvitationOperationCommand
    public let quotaIntent: V2ActorGroupJoinQuotaIntentWire?
    public init(command: V2GroupInvitationOperationCommand, quotaIntent: V2ActorGroupJoinQuotaIntentWire? = nil) {
        self.command = command; self.quotaIntent = quotaIntent
    }
}
