import Synchronization
import IMV2ActorCluster
import IMV2ServerApplication

/// A startup binding; reading the attached Sendable facade never queues behind an Actor.
package final class V2PolicyClusterClientBinding: Sendable {
    private struct State: Sendable {
        var attached: V2RoomClusterClient?
        var qualified: (@Sendable () async -> Bool)?
        var closed = false
    }
    private let state = Mutex(State())
    package init() {}
    package func bind(_ client: V2RoomClusterClient, qualified: @escaping @Sendable () async -> Bool) throws {
        try state.withLock {
            guard !$0.closed else { throw V2PolicyAuthorizationLifecycleError.closed }
            guard $0.attached == nil else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
            $0.attached = client
            $0.qualified = qualified
        }
    }
    package func isQualified() async -> Bool {
        let check = state.withLock { $0.closed ? nil : $0.qualified }
        return await check?() ?? false
    }
    package func client() throws -> V2RoomClusterClient {
        try state.withLock {
            guard !$0.closed else { throw V2PolicyAuthorizationLifecycleError.closed }
            guard let attached = $0.attached else { throw V2PolicyAuthorizationLifecycleError.busy }
            return attached
        }
    }
    package func close() { state.withLock { $0.closed = true; $0.attached = nil; $0.qualified = nil } }
}
