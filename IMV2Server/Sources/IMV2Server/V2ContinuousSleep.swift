import Foundation

/// A cancellable delay on the continuous clock, including system sleep time.
/// Explicit deadlines avoid Task.sleep(for:) cross-module specialization
/// crashes in optimized Apple Swift builds (swiftlang/swift#86204).
public func v2Sleep(for duration: Duration) async throws {
    let clock = ContinuousClock()
    try await clock.sleep(until: clock.now.advanced(by: duration))
}
