import Foundation
import IMV2ActorContracts

/// A publication was rejected by a known bounded capacity gate. This does not
/// classify transport failures, retired routes, or unknown delivery outcomes.
public enum V2RealtimePublicationBackpressure: Error, Equatable, Sendable {
    case routeQueries, globalRPCs, peerRPCs, receiverQueue
}

public enum V2RealtimeDirectoryError: Error, Equatable, Sendable {
    case invalidInput, corruptPersistenceState, capacityExceeded, incarnationConflict, authorityLost, revisionConflict, wrongOwner
}

public struct V2UserSyncWake: Equatable, Sendable {
    public let userID: String
    public let highWatermark: UInt64
    public init(userID: String, highWatermark: UInt64) { self.userID = userID; self.highWatermark = highWatermark }
}
public struct V2UserSyncWakeLease: Equatable, Sendable {
    public let wake: V2UserSyncWake
    public let revision: Int64
    public let claimToken: UUID
    public let attempt: Int
    public init(wake: V2UserSyncWake, revision: Int64, claimToken: UUID, attempt: Int) {
        self.wake = wake; self.revision = revision; self.claimToken = claimToken; self.attempt = attempt
    }
}
public protocol V2UserSyncWakeStore: Sendable {
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) async throws -> [V2UserSyncWakeLease]
    func markPublished(_ lease: V2UserSyncWakeLease) async throws
    func scheduleRetry(_ lease: V2UserSyncWakeLease, nextAttemptAt: Date) async throws
}
public protocol V2UserSyncWakePublishing: Sendable {
    func publish(_ wake: V2UserSyncWake) async throws
}
