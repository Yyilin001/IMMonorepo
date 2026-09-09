import Foundation
@testable import IMV2Core
import Testing

@Suite("Group invitation domain")
struct GroupInvitationTests {
    @Test("invite secrets accept only a 256-bit base64url representation and redact descriptions")
    func validatesAndRedactsSecrets() throws {
        let secret = try V2GroupInviteSecret(String(repeating: "A", count: 43))

        #expect(secret.rawValue.count == 43)
        #expect(secret.description == "<redacted-group-invite-secret>")
        #expect(secret.debugDescription == "<redacted-group-invite-secret>")
        #expect(throws: V2GroupInvitationValidationError.invalidSecret) {
            _ = try V2GroupInviteSecret(String(repeating: "A", count: 42))
        }
        #expect(throws: V2GroupInvitationValidationError.invalidSecret) {
            _ = try V2GroupInviteSecret(String(repeating: "A", count: 42) + "+")
        }
    }

    @Test("preview requires request state and request identifier to agree")
    func validatesPreviewRequestIdentity() throws {
        #expect(throws: V2GroupInvitationValidationError.invalidPreview) {
            _ = try V2GroupInvitePreview(
                inviteID: inviteID(1),
                roomID: roomID(2),
                roomTitle: "安全群",
                expiresAt: Date(timeIntervalSince1970: 2_000),
                requestState: .pending,
                requestID: nil,
                isAlreadyMember: false
            )
        }
    }

    @Test("join request exposes a resume operation only while approval is in progress")
    func validatesApprovalResumeMarker() throws {
        let identity = try V2PublicIdentity(
            userID: userID(3),
            handle: .init("applicant_3"),
            displayName: "申请人",
            accountKind: .regular
        )

        #expect(throws: V2GroupInvitationValidationError.invalidRequest) {
            _ = try V2GroupJoinRequest(
                requestID: requestID(4),
                inviteID: inviteID(5),
                roomID: roomID(6),
                applicant: identity,
                note: nil,
                state: .pending,
                resumableDecisionOperationID: decisionID(7),
                createdAt: Date(timeIntervalSince1970: 1_000),
                decidedAt: nil
            )
        }
    }
}

private func uuid(_ suffix: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012d", suffix)
}

private func inviteID(_ suffix: Int) -> GroupInviteID { try! .init(uuid(suffix)) }
private func roomID(_ suffix: Int) -> RoomID { try! .init(uuid(suffix)) }
private func userID(_ suffix: Int) -> UserID { try! .init(uuid(suffix)) }
private func requestID(_ suffix: Int) -> GroupJoinRequestID { try! .init(uuid(suffix)) }
private func decisionID(_ suffix: Int) -> GroupJoinDecisionOperationID { try! .init(uuid(suffix)) }
