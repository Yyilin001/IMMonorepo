import Foundation
import XCTest
@testable import IMV2Core

final class ApplicationOperationTests: XCTestCase {
    func testFingerprintIsIndependentOfFieldOrderButPreservesSemanticChanges() throws {
        let fields: [V2OperationFingerprintField] = [.init("nickname", .text("a")), .init("expectedRevision", .unsigned(4))]
        let a = try V2OperationFingerprint(kind: .profileUpdate, fields: fields)
        XCTAssertEqual(a.digest.map { String(format: "%02x", $0) }.joined(), "4f10acc1b5e38705dae5f7054bbcdc6049595d45a3c737a0af680d7cd8c4abb6")
        XCTAssertEqual(a, try V2OperationFingerprint(kind: .profileUpdate, fields: fields.reversed()))
        XCTAssertNotEqual(a, try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("nickname", .text("a")), .init("expectedRevision", .unsigned(5))]))
        XCTAssertNotEqual(try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("x", .absent)]), try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("x", .text(""))]))
        XCTAssertThrowsError(try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("x", .text("a")), .init("x", .text("b"))]))
    }
    func testIdentityRejectsAccountAndDomainScopeConfusionIncludingDecode() throws {
        let user = try UserID("u"), other = try UserID("v")
        let identity = try V2OperationIdentity(accountID: user, scope: .account(user), operation: .profileUpdate(ProfileUpdateOperationID("op")))
        XCTAssertEqual(try JSONDecoder().decode(V2OperationIdentity.self, from: JSONEncoder().encode(identity)), identity)
        XCTAssertThrowsError(try V2OperationIdentity(accountID: user, scope: .account(other), operation: identity.operation))
        XCTAssertThrowsError(try V2OperationIdentity(accountID: user, scope: .room(RoomID("room")), operation: identity.operation))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        object["accountID"] = ["rawValue": "v"]
        XCTAssertThrowsError(try JSONDecoder().decode(V2OperationIdentity.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testEveryKindHasPolicyAndDeadlineNeverRejectsAnUnknownResult() {
        for kind in V2OperationKind.allCases {
            let policy = V2CommandPolicy.registered(for: kind)
            XCTAssertEqual(policy.kind, kind)
            XCTAssertEqual(policy.maximumAutomaticAttempts, 5)
            XCTAssertEqual(policy.actionAtDeadline(submission: .submissionStarted), .recoverOriginalIdentity)
            XCTAssertEqual(policy.actionAtDeadline(submission: .neverSubmitted), .expireUnsubmitted)
        }
        XCTAssertEqual(V2AuthenticationPolicy.oneTimeProof.replay, .forbidden)
        XCTAssertEqual(V2AuthenticationPolicy.credentialOperation.replay, .sameIdentity)
        XCTAssertNil(V2CommandPolicy.registered(for: .readReceipt).firstSubmissionWindowMilliseconds)
        XCTAssertFalse(V2OperationExecutionState.awaitingConfirmation.isTerminal)
        XCTAssertFalse(V2OperationExecutionState.processing.isTerminal)
    }
    func testUnresolvedAndFingerprintConflictNeverProvideAnAuthoritativeOutcome() throws {
        enum Receipt: String, Codable, Sendable { case domainConfirmed }
        XCTAssertNil(V2OperationRecoveryResult<Receipt>.unresolved.authoritativeOutcome)
        XCTAssertNil(V2OperationRecoveryResult<Receipt>.fingerprintConflict.authoritativeOutcome)
        XCTAssertEqual(V2OperationRecoveryResult<Receipt>.committed(.domainConfirmed).authoritativeOutcome, .committed(.domainConfirmed))
        XCTAssertEqual(V2OperationRecoveryResult<Receipt>.processing(.domainConfirmed, nextQueryAfterMilliseconds: 100).authoritativeOutcome, .processing(.domainConfirmed, nextQueryAfterMilliseconds: 100))
    }
    func testMalformedStoredFingerprintCannotBypassValidation() throws {
        XCTAssertThrowsError(try V2OperationFingerprint(version: 1, digest: Data(count: 31)))
        let raw = Data("{\"version\":1,\"digest\":\"AA==\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(V2OperationFingerprint.self, from: raw))
    }
}
