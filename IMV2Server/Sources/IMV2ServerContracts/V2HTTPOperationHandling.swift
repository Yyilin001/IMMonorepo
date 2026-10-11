import Foundation
import IMV2Core

/// Account-owned operations exposed to HTTP without a persistence dependency.
public enum V2HTTPOperationError: Error {
    case actorInactive
}

public protocol V2SocialOperationHandling: Sendable {
    func loadSocialOperationSnapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2SocialOperationSnapshot
    func submitSocialOperation(_ command: V2SocialOperationCommand) async throws -> V2SocialOperationRecoveryResult
    func recoverSocialOperation(_ request: V2SocialOperationRecoveryRequest, now: Date) async throws -> V2SocialOperationRecoveryResult
}

public protocol V2AccountPreferenceOperationHandling: Sendable {
    func loadAccountPreferenceSnapshot(ownerUserID: UserID, kind: V2OperationKind) async throws -> V2AccountPreferenceSnapshot
    func submit(_ command: V2AccountPreferenceCommand, now: Date) async throws -> V2AccountPreferenceRecoveryResult
    func recover(_ request: V2AccountPreferenceRecoveryRequest, now: Date) async throws -> V2AccountPreferenceRecoveryResult
}

public protocol V2DirectRoomOperationHandling: Sendable {
    func submit(_ command: V2DirectRoomOperationCommand, now: Date, deadline: ContinuousClock.Instant) async throws -> V2DirectRoomOperationResult
    func recover(_ request: V2DirectRoomOperationRecoveryRequest, now: Date, deadline: ContinuousClock.Instant) async throws -> V2DirectRoomOperationResult
}

public protocol V2GroupCreationOperationHandling: Sendable {
    func begin(_ intent: V2GroupCreationIntent, now: Date) async throws -> V2GroupCreationOperationResult
    func append(_ request: V2GroupCreationAppendRequest, now: Date) async throws -> V2GroupCreationOperationResult
    func finalize(_ intent: V2GroupCreationIntent, now: Date, deadline: ContinuousClock.Instant) async throws -> V2GroupCreationOperationResult
    func recover(_ request: V2GroupCreationRecoveryRequest, now: Date) async throws -> V2GroupCreationOperationResult
}
