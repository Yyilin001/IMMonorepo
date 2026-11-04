import Foundation
import os

/// A session-owned server time estimate. Device wall-clock changes cannot extend
/// command windows after the authenticated connection establishes this anchor.
public final class V2ServerTimeAnchor: Sendable {
    public enum Failure: Error, Sendable { case unavailable, invalidSample, submissionExpired }
    private struct Sample: Sendable {
        let milliseconds: Int64
        let receivedAt: ContinuousClock.Instant
    }
    private let sample = OSAllocatedUnfairLock<Sample?>(initialState: nil)
    public init() {}

    public func observe(milliseconds: Int64, receivedAt: ContinuousClock.Instant = .now) throws {
        guard milliseconds > 0 else { throw Failure.invalidSample }
        sample.withLock { $0 = Sample(milliseconds: milliseconds, receivedAt: receivedAt) }
    }

    func submissionDeadline(localDeadline: UInt64, localNow: Date, maximumRemainingSeconds: Double) throws -> UInt64 {
        let remaining = Double(localDeadline) / 1000 - localNow.timeIntervalSince1970
        guard remaining > 0 else { throw Failure.submissionExpired }
        let milliseconds = (try now().timeIntervalSince1970 + min(remaining, maximumRemainingSeconds)) * 1000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds < Double(UInt64.max) else { throw Failure.invalidSample }
        return UInt64(milliseconds)
    }

    public func reset() { sample.withLock { $0 = nil } }

    public func now(at instant: ContinuousClock.Instant = .now) throws -> Date {
        try sample.withLock { value in
            guard let value else { throw Failure.unavailable }
            let elapsed = value.receivedAt.duration(to: instant)
            guard elapsed >= .zero, elapsed <= .seconds(3600) else { throw Failure.unavailable }
            let parts = elapsed.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            return Date(timeIntervalSince1970: Double(value.milliseconds) / 1000 + seconds)
        }
    }
}
