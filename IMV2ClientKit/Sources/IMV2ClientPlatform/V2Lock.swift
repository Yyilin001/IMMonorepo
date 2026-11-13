import Foundation
#if canImport(os)
import os
#endif

/// Small synchronous state boundary. Apple keeps the existing unfair-lock
/// implementation; other platforms use Foundation's mutex. No async work may
/// execute while the lock is held. State is never exposed outside withLock.
public final class V2Lock<State>: @unchecked Sendable {
    #if canImport(os)
    private let storage: OSAllocatedUnfairLock<State>
    public init(initialState: State) { storage = .init(uncheckedState: initialState) }
    public func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try storage.withLockUnchecked(body)
    }
    #else
    private let lock = NSLock()
    private var state: State
    public init(initialState: State) { state = initialState }
    public func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
    #endif
}
