import Foundation
import IMV2Core

/// Durable notification responsibility, not message content or permission to read it.
public struct V2AccountNotification: Sendable {
    public let userID: UserID
    public let eventID: UUID
    public let messageID: MessageID
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let membershipRevision: UInt64
    public let senderID: UserID
    public let isMention: Bool
    public let createdAt: Date
    public init(userID: UserID, eventID: UUID, messageID: MessageID, roomID: RoomID,
                roomSequence: UInt64, membershipRevision: UInt64, senderID: UserID,
                isMention: Bool, createdAt: Date) {
        self.userID = userID; self.eventID = eventID; self.messageID = messageID; self.roomID = roomID
        self.roomSequence = roomSequence; self.membershipRevision = membershipRevision
        self.senderID = senderID; self.isMention = isMention; self.createdAt = createdAt
    }
}
public struct V2AccountNotificationLease: Sendable {
    public let notification: V2AccountNotification
    public let token: UUID
    public let expiresAt: Date
    public let attempt: Int
    public init(notification: V2AccountNotification, token: UUID, expiresAt: Date, attempt: Int) {
        self.notification = notification; self.token = token; self.expiresAt = expiresAt; self.attempt = attempt
    }
}
public protocol V2AccountNotificationStoring: Sendable {
    func expire(now: Date, limit: Int) async throws -> Int
    func claim(now: Date, limit: Int) async throws -> [V2AccountNotificationLease]
    func complete(_ lease: V2AccountNotificationLease, now: Date) async throws -> Bool
    func retry(_ lease: V2AccountNotificationLease, now: Date, after: TimeInterval) async throws
}

/// Reserved alert delivery boundary. A future implementation must durably plan
/// per-device work, recheck membership/read/mute/account/device eligibility and
/// bind endpoint generation. No online-room subscription is an eligibility test.
/// Returning accepted means durable downstream responsibility, never device display.
/// Implementations must be idempotent by (userID,eventID), respect cancellation,
/// and impose a bounded network deadline. APNs credentials alone do not enable this.
public protocol V2AccountNotificationDelivering: Sendable {
    func deliver(_ notification: V2AccountNotification) async throws -> V2AccountNotificationOutcome
}
public enum V2AccountNotificationOutcome: Sendable { case accepted, suppressed, retry }
public enum V2AccountNotificationLimits {
    public static let lifetime: TimeInterval = 24 * 60 * 60
}
