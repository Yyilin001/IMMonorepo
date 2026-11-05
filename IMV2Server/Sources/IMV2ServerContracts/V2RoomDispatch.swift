import Foundation
import IMV2Core

/// A page lease never grants authority to mutate a room. The room Actor already
/// committed these facts; this worker only enumerates its historical audience.
public struct V2RoomDispatchLease: Sendable {
    public let eventID: UUID
    public let messageID: UUID?
    public let roomID: RoomID
    public let roomSequence: UInt64
    public let membershipRevision: UInt64
    public let senderID: UserID?
    public let mentionedUserIDs: Set<UserID>
    public let mentionsEveryone: Bool
    package let createdAtTimestamp: V2PersistenceTimestamp
    public var createdAt: Date { createdAtTimestamp.date }
    public let recipientCursor: UUID?
    public let token: UUID
    public let attempt: Int
    public let expiresAt: Date

    package init(eventID: UUID, messageID: UUID?, roomID: RoomID, roomSequence: UInt64,
                 membershipRevision: UInt64, senderID: UserID?, mentionedUserIDs: Set<UserID>,
                 mentionsEveryone: Bool, createdAtTimestamp: V2PersistenceTimestamp,
                 recipientCursor: UUID?, token: UUID, attempt: Int, expiresAt: Date) {
        self.eventID = eventID; self.messageID = messageID; self.roomID = roomID
        self.roomSequence = roomSequence; self.membershipRevision = membershipRevision
        self.senderID = senderID; self.mentionedUserIDs = mentionedUserIDs; self.mentionsEveryone = mentionsEveryone
        self.createdAtTimestamp = createdAtTimestamp; self.recipientCursor = recipientCursor
        self.token = token; self.attempt = attempt; self.expiresAt = expiresAt
    }
}

public enum V2RoomDispatchError: Error, Sendable {
    case invalidInput, corruptPersistence, lostLease
}

public struct V2RoomDispatchAcknowledgement: Sendable {
    public let lease: V2RoomDispatchLease
    public let through: UUID?
    public init(lease: V2RoomDispatchLease, through: UUID?) { self.lease=lease; self.through=through }
}
public protocol V2RoomDispatchOutbox: Sendable {
    func acknowledgePages(_ pages: [V2RoomDispatchAcknowledgement], now: Date) async throws -> Set<UUID>

    func claim(now: Date, limit: Int, leaseDuration: TimeInterval) async throws -> [V2RoomDispatchLease]
    func recipients(_ lease: V2RoomDispatchLease, limit: Int, now: Date) async throws -> [UserID]
    func acknowledgePage(_ lease: V2RoomDispatchLease, through cursor: UUID?, now: Date) async throws -> Bool
    func retry(_ lease: V2RoomDispatchLease, now: Date, after delay: TimeInterval) async throws
}

/// Returning means the target account durably owns both its sync hint and its
/// notification intent, regardless of any current connection or APNs setting.
public struct V2RoomDispatchTarget: Sendable {
    public let userID: UserID
    public let leases: [V2RoomDispatchLease]
    public init(userID: UserID, leases: [V2RoomDispatchLease]) {
        self.userID = userID; self.leases = leases
    }
}

public protocol V2RoomDispatchProjecting: Sendable {
    /// Only returned users have durably accepted every item; omissions retry.
    func projectTargets(_ targets: [V2RoomDispatchTarget]) async throws -> Set<UserID>

    func project(_ lease: V2RoomDispatchLease, to userID: UserID) async throws
    /// Batches already-committed changes for one account, never room writes.
    func project(_ leases: [V2RoomDispatchLease], to userID: UserID) async throws
}

extension V2RoomDispatchProjecting {
    public func projectTargets(_ targets: [V2RoomDispatchTarget]) async throws -> Set<UserID> {
        var accepted = Set<UserID>()
        for target in targets {
            try Task.checkCancellation()
            do { try await project(target.leases, to: target.userID); accepted.insert(target.userID) }
            catch is CancellationError { throw CancellationError() }
            catch { /* The source still owns this target's delivery. */ }
        }
        return accepted
    }

    public func project(_ leases: [V2RoomDispatchLease], to userID: UserID) async throws {
        for lease in leases { try await project(lease, to: userID) }
    }
}

extension V2RoomDispatchOutbox {
    public func acknowledgePages(_ pages: [V2RoomDispatchAcknowledgement], now: Date) async throws -> Set<UUID> {
        var accepted = Set<UUID>()
        for page in pages {
            try Task.checkCancellation()
            if try await acknowledgePage(page.lease, through: page.through, now: now) { accepted.insert(page.lease.eventID) }
        }
        return accepted
    }
}
