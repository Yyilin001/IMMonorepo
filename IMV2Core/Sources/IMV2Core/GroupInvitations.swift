import Foundation

/// A high-entropy bearer secret carried by a share link or QR code. The
/// server never persists this plaintext value; storage adapters receive only
/// its digest. Restricting the alphabet also makes copy/paste and URL parsing
/// deterministic across clients.
public struct V2GroupInviteSecret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 43,
              rawValue.utf8.allSatisfy({ byte in
                  switch byte {
                  case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39, 0x2D, 0x5F:
                      true
                  default:
                      false
                  }
              })
        else { throw V2GroupInvitationValidationError.invalidSecret }
        self.rawValue = rawValue
    }

    /// Deliberately redacted so accidental interpolation never emits the
    /// bearer secret to logs or diagnostics.
    public var description: String { "<redacted-group-invite-secret>" }
    public var debugDescription: String { description }
}

public enum V2GroupInviteState: String, Codable, Equatable, Sendable {
    case active
    case revoked
    case expired
    case exhausted
}

public enum V2GroupJoinRequestState: String, Codable, Equatable, Sendable {
    case pending
    case approving
    case approved
    case rejected
}

public enum V2GroupJoinDecision: String, Codable, Equatable, Sendable {
    case approve
    case reject
}

public struct V2GroupInviteLink: Equatable, Sendable, Identifiable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let roomTitle: String
    public let secret: V2GroupInviteSecret
    public let state: V2GroupInviteState
    public let expiresAt: Date
    public let maximumApprovedUses: Int
    public let approvedUseCount: Int
    public let createdAt: Date

    public var id: GroupInviteID { inviteID }

    public init(
        inviteID: GroupInviteID,
        roomID: RoomID,
        roomTitle: String,
        secret: V2GroupInviteSecret,
        state: V2GroupInviteState,
        expiresAt: Date,
        maximumApprovedUses: Int,
        approvedUseCount: Int,
        createdAt: Date
    ) throws {
        let title = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 120,
              maximumApprovedUses > 0,
              approvedUseCount >= 0,
              approvedUseCount <= maximumApprovedUses,
              expiresAt > createdAt
        else { throw V2GroupInvitationValidationError.invalidLink }
        self.inviteID = inviteID
        self.roomID = roomID
        self.roomTitle = title
        self.secret = secret
        self.state = state
        self.expiresAt = expiresAt
        self.maximumApprovedUses = maximumApprovedUses
        self.approvedUseCount = approvedUseCount
        self.createdAt = createdAt
    }
}

public struct V2GroupInvitePreview: Equatable, Sendable {
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let roomTitle: String
    public let expiresAt: Date
    public let requestState: V2GroupJoinRequestState?
    public let requestID: GroupJoinRequestID?
    public let isAlreadyMember: Bool

    public init(
        inviteID: GroupInviteID,
        roomID: RoomID,
        roomTitle: String,
        expiresAt: Date,
        requestState: V2GroupJoinRequestState?,
        requestID: GroupJoinRequestID?,
        isAlreadyMember: Bool
    ) throws {
        let title = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 120,
              (requestState == nil) == (requestID == nil)
        else { throw V2GroupInvitationValidationError.invalidPreview }
        self.inviteID = inviteID
        self.roomID = roomID
        self.roomTitle = title
        self.expiresAt = expiresAt
        self.requestState = requestState
        self.requestID = requestID
        self.isAlreadyMember = isAlreadyMember
    }
}

public struct V2GroupJoinRequest: Equatable, Sendable, Identifiable {
    public let requestID: GroupJoinRequestID
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let applicant: V2PublicIdentity
    public let note: String?
    public let state: V2GroupJoinRequestState
    /// Present only while the same reviewer can safely resume a decision that
    /// may have crossed a process crash after membership was committed.
    public let resumableDecisionOperationID: GroupJoinDecisionOperationID?
    public let createdAt: Date
    public let decidedAt: Date?

    public var id: GroupJoinRequestID { requestID }

    public init(
        requestID: GroupJoinRequestID,
        inviteID: GroupInviteID,
        roomID: RoomID,
        applicant: V2PublicIdentity,
        note: String?,
        state: V2GroupJoinRequestState,
        resumableDecisionOperationID: GroupJoinDecisionOperationID?,
        createdAt: Date,
        decidedAt: Date?
    ) throws {
        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedNote?.utf8.count ?? 0 <= 500,
              state == .approving || resumableDecisionOperationID == nil,
              state == .approved || state == .rejected || decidedAt == nil
        else { throw V2GroupInvitationValidationError.invalidRequest }
        self.requestID = requestID
        self.inviteID = inviteID
        self.roomID = roomID
        self.applicant = applicant
        self.note = normalizedNote?.isEmpty == false ? normalizedNote : nil
        self.state = state
        self.resumableDecisionOperationID = resumableDecisionOperationID
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

public struct V2GroupJoinRequestPage: Equatable, Sendable {
    public let requests: [V2GroupJoinRequest]
    public let nextCursor: String?

    public init(requests: [V2GroupJoinRequest], nextCursor: String?) {
        self.requests = requests
        self.nextCursor = nextCursor
    }
}

public enum V2GroupInvitationValidationError: Error, Equatable, Sendable {
    case invalidSecret
    case invalidLink
    case invalidPreview
    case invalidRequest
}
