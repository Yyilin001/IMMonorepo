@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

protocol V2SocialSnapshotTestReading {
    func socialOperationSnapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2SocialOperationSnapshot
}
extension PostgresV2SocialRelationshipStore: V2SocialSnapshotTestReading {}
extension V2PostgresSocialRelationshipPersistence: V2SocialSnapshotTestReading {}

extension V2SocialSnapshotTestReading {
    /// Freezes a freshly observed baseline for a new fixture operation. Tests
    /// of replay retain the returned command and call submitSocialOperation.
    func freezeSocialFixture(actorUserID: UserID, targetUserID: UserID,
        operation: V2OperationReference, action: V2SocialOperationAction, now: Date) async throws -> V2SocialOperationCommand {
        let baseline = try await socialOperationSnapshot(actorUserID: actorUserID, targetUserID: targetUserID)
        let revision = action.kind == .relationship ? baseline.relationshipRevision : baseline.blockRevision
        guard let milliseconds = UInt64(exactly: try v2GatewayMilliseconds(now)) else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
        let window = V2CommandPolicy.registered(for: action.kind).firstSubmissionWindowMilliseconds!
        guard milliseconds <= UInt64(Int64.max)-window else { throw V2SocialRelationshipStoreError.corruptPersistenceState }
        return try .init(identity: .init(accountID: actorUserID, scope: .userPair(actorUserID, targetUserID), operation: operation),
            action: action, expectedRevision: revision, firstSubmissionDeadlineMilliseconds: milliseconds + window)
    }

}

extension PostgresV2SocialRelationshipStore {
    func executeSocialFixture(actorUserID: UserID, targetUserID: UserID,
        operation: V2OperationReference, action: V2SocialOperationAction, now: Date) async throws -> V2SocialOperationRecoveryResult {
        let command = try await freezeSocialFixture(actorUserID: actorUserID, targetUserID: targetUserID,
            operation: operation, action: action, now: now)
        return try await submitSocialOperation(command)
    }
}

protocol V2AccountPreferenceTestOperating {
    func snapshot(ownerUserID: UserID, kind: V2OperationKind) async throws -> V2AccountPreferenceSnapshot
    func submit(_ command: V2AccountPreferenceCommand, now: Date) async throws -> V2AccountPreferenceRecoveryResult
}
extension PostgresV2AccountPreferenceOperationStore: V2AccountPreferenceTestOperating {}
extension V2PostgresAccountPreferencePersistence: V2AccountPreferenceTestOperating {}

extension V2AccountPreferenceTestOperating {
    /// Initial authority observation only; replay tests retain this command.
    func freezePreferenceFixture(owner: UserID, operation: V2OperationReference,
        value: V2AccountPreferenceValue, now: Date) async throws -> V2AccountPreferenceCommand {
        let baseline = try await snapshot(ownerUserID: owner, kind: value.kind)
        guard let milliseconds = UInt64(exactly: try v2GatewayMilliseconds(now)), milliseconds <= UInt64(Int64.max)-120_000 else {
            throw V2AccountPreferenceValidationError.invalidCommand
        }
        return try .init(identity: .init(accountID: owner, scope: .account(owner), operation: operation),
            value: value, expectedRevision: baseline.revision, firstSubmissionDeadlineMilliseconds: milliseconds + 120_000)
    }

    func executePreferenceFixture(owner: UserID, operation: V2OperationReference,
        value: V2AccountPreferenceValue, now: Date) async throws -> V2AccountPreferenceRecoveryResult {
        let command = try await freezePreferenceFixture(owner: owner, operation: operation, value: value, now: now)
        return try await submit(command, now: now)
    }
}
