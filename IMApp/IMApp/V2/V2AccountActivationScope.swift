import Foundation

/// Construction owns account resources until a synchronous publication hands
/// them to AppStore. Every early return, throw and cancellation drains anything
/// already constructed; asynchronous cleanup must not live in deinit or defer.
@MainActor
final class V2AccountActivationScope {
    private var cleanup: [@MainActor () async throws -> Void] = []
    private var adopted = false

    static func withPrepared<Value>(_ operation: @MainActor (V2AccountActivationScope) async throws -> Value) async throws -> Value {
        let scope = V2AccountActivationScope()
        let value: Value
        do { value = try await operation(scope) }
        catch {
            try await scope.discardIfNeeded()
            throw error
        }
        try await scope.discardIfNeeded()
        return value
    }

    func onDiscard(_ action: @escaping @MainActor () async throws -> Void) {
        precondition(!adopted)
        cleanup.append(action)
    }

    /// Call immediately before assigning all resources to their new owner,
    /// without another suspension until publication is complete.
    func adopt() throws {
        try Task.checkCancellation()
        precondition(!adopted)
        adopted = true
        cleanup.removeAll()
    }

    private func discardIfNeeded() async throws {
        guard !adopted else { return }
        let pending = Array(cleanup.reversed())
        cleanup.removeAll()
        try await V2AccountResourceCleanup.run(pending)
    }
}

/// A cache deletion failure must not skip draining the journal, uploads, or
/// staging owner. Report the first failure after every owner has been visited.
@MainActor
enum V2AccountResourceCleanup {
    static func run(_ actions: [@MainActor () async throws -> Void]) async throws {
        var firstError: (any Error)?
        for action in actions {
            do { try await action() }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}
