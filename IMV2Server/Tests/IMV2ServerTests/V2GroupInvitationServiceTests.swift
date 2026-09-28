import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 group invitation service")
struct V2GroupInvitationServiceTests {
    @Test("Invitation lifetime policy rejects nonrepresentable integer seconds")
    func policyLifetimeBounds() throws {
        for maximum in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max), Double(Int.max).nextUp, 0, -1] {
            #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                _ = try V2GroupInvitationPolicy(maximumLifetime: maximum)
            }
        }
        for minimum in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 0, -1] {
            #expect(throws: V2GroupInvitationServiceError.invalidRequest) {
                _ = try V2GroupInvitationPolicy(minimumLifetime: minimum)
            }
        }
        let largest = Double(Int.max).nextDown
        #expect(try V2GroupInvitationPolicy(maximumLifetime: largest).maximumLifetime == largest)
        #expect(try V2GroupInvitationPolicy() == .standard)
    }

    @Test("issuer is retry stable, domain scoped, and stores only a digest")
    func issuesRetryStableSecret() throws {
        let issuer = try V2GroupInviteSecretIssuer(rawKey: Data(repeating: 0x2A, count: 32))
        let actor = try UserID("00000000-0000-0000-0000-000000000101")
        let operation = try GroupInviteOperationID("00000000-0000-0000-0000-000000000102")

        let first = try issuer.secret(actorUserID: actor, operationID: operation)
        let retry = try issuer.secret(actorUserID: actor, operationID: operation)
        let another = try issuer.secret(
            actorUserID: actor,
            operationID: .init("00000000-0000-0000-0000-000000000103")
        )

        #expect(first == retry)
        #expect(first != another)
        #expect(first.description == "<redacted-group-invite-secret>")
        #expect(issuer.digest(first).count == 32)
        #expect(issuer.digest(first) != Data(first.rawValue.utf8))
    }

}
