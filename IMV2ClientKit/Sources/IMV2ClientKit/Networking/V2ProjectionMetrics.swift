import Foundation
import Synchronization

/// Callback interval includes other transaction observers; it is not a pure
/// SQLite fsync measurement. Snapshot publication is not a rendered GPU frame.
public struct V2ProjectionMetric: Sendable {
    public enum Phase: String, Sendable { case willCommitToDidCommit, didCommitToConversationSnapshot }
    public let phase: Phase
    public let elapsed: TimeInterval
    public let scopes: V2ProjectionScopes
}

/// An opaque, account-owned monotonic stamp. No database identity is retained.
public final class V2ConversationCommitMeasurement: Sendable {
    let committedAt: ContinuousClock.Instant
    private let diagnostics: V2NetworkDiagnostics
    private let consumed = Mutex(false)
    init(committedAt: ContinuousClock.Instant, diagnostics: V2NetworkDiagnostics) {
        self.committedAt = committedAt; self.diagnostics = diagnostics
    }
    public func didPublishSnapshot() {
        guard !Task.isCancelled else { return }
        let first = consumed.withLock { value in if value { return false }; value = true; return true }
        guard first else { return }
        let duration = committedAt.duration(to: .now).components
        diagnostics.record(.init(phase: .didCommitToConversationSnapshot,
            elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18, scopes: .conversations))
    }
    public static func earliest(_ first: V2ConversationCommitMeasurement?, _ second: V2ConversationCommitMeasurement?) -> V2ConversationCommitMeasurement? {
        let first: V2ConversationCommitMeasurement? = first.flatMap { measurement in
            measurement.consumed.withLock { value in value } ? nil : measurement
        }
        let second: V2ConversationCommitMeasurement? = second.flatMap { measurement in
            measurement.consumed.withLock { value in value } ? nil : measurement
        }
        guard let first else { return second }
        guard let second else { return first }
        return first.committedAt <= second.committedAt ? first : second
    }
}
public enum V2ProjectionVisibilityScope {
    @TaskLocal public static var conversationCommit: V2ConversationCommitMeasurement?
}
