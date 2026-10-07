import Synchronization

/// Cancels only the pool's ungranted queue ticket. Physical SQL lifetime is
/// still owned by V2RoomPhysicalTransactionState and its actual future.
package final class V2ConnectionAcquisitionCancellation: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var callback: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())
    func install(_ callback: @escaping @Sendable () -> Void) {
        let cancel = state.withLock { value in
            if value.cancelled { return true }
            value.callback = callback; return false
        }
        if cancel { callback() }
    }
    func cancel() {
        let callback = state.withLock { value -> (@Sendable () -> Void)? in
            guard !value.cancelled else { return nil }
            value.cancelled = true
            let callback = value.callback; value.callback = nil
            return callback
        }
        callback?()
    }
}
