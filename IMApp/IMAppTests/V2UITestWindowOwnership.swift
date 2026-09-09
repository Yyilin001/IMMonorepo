import Foundation

/// Swift Testing runs suites concurrently. Tests that temporarily own the
/// simulator's key window must finish and restore it before another starts.
@MainActor
enum V2UITestWindowOwnership {
    private static var occupied = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        if occupied { await withCheckedContinuation { waiters.append($0) } }
        else { occupied = true }
    }

    static func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}
