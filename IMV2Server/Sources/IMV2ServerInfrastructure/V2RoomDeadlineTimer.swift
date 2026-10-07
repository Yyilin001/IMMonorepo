import Foundation
import NIOCore
import Synchronization

/// Disarming synchronously settles the callback boundary. A cancelled timer's
/// queued callback must not close a connection after its loan has ended.
package final class V2RoomDeadlineGuard: Sendable {
    private let active = Mutex(true)

    func fire(_ action: () -> Void) {
        active.withLock { value in
            guard value else { return }
            value = false
            action()
        }
    }

    func disarm() { active.withLock { $0 = false } }
}

package final class V2RoomDeadlineTimer: Sendable {
    private let guardState = V2RoomDeadlineGuard()
    private let scheduled: Scheduled<Void>

    init(deadline: ContinuousClock.Instant, eventLoop: any EventLoop,
         action: @escaping @Sendable () -> Void) {
        let remaining = ContinuousClock.now.duration(to: deadline)
        let parts = remaining.components
        let nanoseconds = max(0, parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000)
        let guardState = self.guardState
        scheduled = eventLoop.scheduleTask(in: .nanoseconds(nanoseconds)) {
            guardState.fire(action)
        }
    }

    func disarm() {
        guardState.disarm()
        scheduled.cancel()
    }
}
