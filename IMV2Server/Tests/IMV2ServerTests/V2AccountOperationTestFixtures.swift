import FluentKit
import Foundation
import IMV2Core
@testable import IMV2Server

extension PostgresV2SocialRelationshipStore {
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

    func executeSocialFixture(actorUserID: UserID, targetUserID: UserID,
        operation: V2OperationReference, action: V2SocialOperationAction, now: Date) async throws -> V2SocialOperationRecoveryResult {
        let command = try await freezeSocialFixture(actorUserID: actorUserID, targetUserID: targetUserID,
            operation: operation, action: action, now: now)
        return try await submitSocialOperation(command, now: now)
    }
}

extension PostgresV2AccountPreferenceOperationStore {
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
