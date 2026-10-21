import Foundation
import IMV2Core

/// Captures the displayed baseline and the user's original click before any await.
/// A restored draft cannot recreate this activation-local authorization.
public struct V2GroupCapabilityConfirmationWindow: Sendable {
    public let intent: V2GroupCapabilityIntent
    public let deadline: ContinuousClock.Instant
    let activationID: UUID

    public init(accountID: UserID, roomID: RoomID, action: V2GroupCapabilityAction, activationID: UUID) throws {
        try self.init(accountID: accountID, roomID: roomID, action: action, activationID: activationID, wallNow: Date(), monotonicNow: .now)
    }

    init(accountID: UserID, roomID: RoomID, action: V2GroupCapabilityAction, activationID: UUID, wallNow: Date, monotonicNow: ContinuousClock.Instant) throws {
        let milliseconds = (wallNow.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(Int64.max) - 120_000,
              let timestamp = UInt64(exactly: milliseconds) else { throw V2OperationWorkError.invalidRecord }
        let operation: V2OperationReference
        let scope: V2OperationScope
        switch action {
        case .pin(let messageID, _, _):
            operation = .pinnedMessage(.init(uuid: UUID()))
            scope = .message(roomID, messageID)
        case .announcement:
            operation = .groupAnnouncement(.init(uuid: UUID()))
            scope = .room(roomID)
        case .rolePermissions:
            operation = .groupPermission(.init(uuid: UUID()))
            scope = .room(roomID)
        case .memberRole:
            operation = .groupRole(.init(uuid: UUID()))
            scope = .room(roomID)
        }
        self.intent = try .init(identity: .init(accountID: accountID, scope: scope, operation: operation), action: action, confirmedUntilMilliseconds: timestamp + V2ClientSubmissionWindow.confirmationMilliseconds)
        self.deadline = monotonicNow.advanced(by: .seconds(V2ClientSubmissionWindow.confirmationSeconds))
        self.activationID = activationID
    }

    func validates(activationID: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        self.activationID == activationID && now < deadline
    }
}
