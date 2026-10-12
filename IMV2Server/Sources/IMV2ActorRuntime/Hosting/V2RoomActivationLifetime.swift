import Foundation
import IMV2ActorContracts

/// Native capability for an exact physical activation. Neither RPC decoding nor
/// a token alone can construct it. Every background SQL scope retains Host
/// ownership until the actual operation and its continuation have settled.
public struct V2RoomActivationLifetime: Sendable {
    public let token: V2RoomActivationToken
    private let begin: @Sendable (UUID, ContinuousClock.Instant) async throws -> ContinuousClock.Instant
    private let validate: @Sendable () async throws -> Void
    private let finish: @Sendable (UUID) async -> Void

    package init(token: V2RoomActivationToken,
                 begin: @escaping @Sendable (UUID, ContinuousClock.Instant) async throws -> ContinuousClock.Instant,
                 validate: @escaping @Sendable () async throws -> Void,
                 finish: @escaping @Sendable (UUID) async -> Void) {
        self.token = token; self.begin = begin; self.validate = validate; self.finish = finish
    }

    public func withPin<Value: Sendable>(deadline: ContinuousClock.Instant,
        _ operation: @Sendable (ContinuousClock.Instant) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()
        let validUntil = try await begin(id, deadline)
        do {
            let value = try await operation(validUntil)
            try Task.checkCancellation()
            guard ContinuousClock.now < validUntil else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
            // Retirement may have begun during SQL. Do not publish new
            // authorization evidence after admission closed.
            try await validate()
            await finish(id)
            return value
        } catch {
            await finish(id)
            throw error
        }
    }
}
