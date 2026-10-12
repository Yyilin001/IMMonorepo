import IMV2ActorContracts

/// Native capability issued for one physically owned restoration. It cannot be
/// decoded from a remote request or reused after that restoration completes.
public struct V2RoomActivationRestorationContext: Sendable {
    public let token: V2RoomActivationToken
    public let lifetime: V2RoomActivationLifetime
    public let deadline: ContinuousClock.Instant
    private let check: @Sendable () async throws -> Void
    package init(token: V2RoomActivationToken, deadline: ContinuousClock.Instant, lifetime: V2RoomActivationLifetime,
                 check: @escaping @Sendable () async throws -> Void) {
        self.token = token; self.deadline = deadline; self.lifetime = lifetime; self.check = check
    }
    public func validate() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        try await check()
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
    }
}
