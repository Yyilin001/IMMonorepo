import Foundation
import IMV2ActorContracts
import IMV2ServerApplication

/// Cache hits and cold loads share the caller deadline, without a second logical queue.
/// The policy Owner coalesces first loads; SQL uses its control connection budget.
package func v2ReadPolicyState<Value: Sendable>(
    callerDeadline: ContinuousClock.Instant,
    cachedOperation: (@Sendable () async throws -> Value?)? = nil,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    do {
        try Task.checkCancellation()
        guard callerDeadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        if let cached = try await cachedOperation?() {
            try Task.checkCancellation()
            guard callerDeadline > .now else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
            return cached
        }
        return try await operation()
    } catch V2PolicyAuthorizationLifecycleError.busy {
        throw V2RoomCallFailure.notAccepted(.overloaded)
    }
}
