import Foundation

/// A post-install authority read has one result for every requested topic.
/// Unavailable never denotes a zero head and cannot satisfy a Ready barrier.
public enum V2RealtimeRecoveryHeadUnavailableReason: String, CaseIterable, Equatable, Sendable {
    case wrongOwner = "wrong_owner", dependency, invalid
}
public enum V2RealtimeRecoveryHeadOutcome: Equatable, Sendable {
    case available(UInt64)
    case unavailable(V2RealtimeRecoveryHeadUnavailableReason)
}
