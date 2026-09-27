import Foundation
import IMV2Core

/// Request facts do not carry a profile display grant. Current applicant names
/// and avatars must use the independent groupJoinReview presentation context.
public struct V2ClientGroupJoinRequest: Equatable, Sendable, Identifiable {
    public let requestID: GroupJoinRequestID
    public let inviteID: GroupInviteID
    public let roomID: RoomID
    public let applicantUserID: UserID
    public let note: String?
    public let state: V2GroupJoinRequestState
    public let resumableDecisionOperationID: GroupJoinDecisionOperationID?
    public let createdAt: Date
    public let decidedAt: Date?
    public var id: GroupJoinRequestID { requestID }
    public var presentationKey: V2ProfileViewLookupKey {
        .init(userID: applicantUserID, context: .groupJoinReview(roomID))
    }

    public init(requestID: GroupJoinRequestID, inviteID: GroupInviteID, roomID: RoomID,
        applicantUserID: UserID, note: String?, state: V2GroupJoinRequestState,
        resumableDecisionOperationID: GroupJoinDecisionOperationID?, createdAt: Date, decidedAt: Date?) throws {
        let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.utf8.count ?? 0 <= 500,
              state == .approving || resumableDecisionOperationID == nil,
              state == .approved || state == .rejected || state == .cancelled || decidedAt == nil,
              createdAt.timeIntervalSince1970.isFinite,
              decidedAt?.timeIntervalSince1970.isFinite ?? true
        else { throw V2ClientGroupInvitationError.invalidResponse }
        self.requestID = requestID; self.inviteID = inviteID; self.roomID = roomID
        self.applicantUserID = applicantUserID; self.note = normalized?.isEmpty == false ? normalized : nil
        self.state = state; self.resumableDecisionOperationID = resumableDecisionOperationID
        self.createdAt = createdAt; self.decidedAt = decidedAt
    }
}

public struct V2ClientGroupJoinRequestPage: Equatable, Sendable {
    public let requests: [V2ClientGroupJoinRequest]
    public let nextCursor: String?
    public init(requests: [V2ClientGroupJoinRequest], nextCursor: String?) {
        self.requests = requests; self.nextCursor = nextCursor
    }
}
