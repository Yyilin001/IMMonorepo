import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization

/// One optional write. The adapter must invoke `enqueueIfCurrent` on its actual
/// socket owner, after checking writability and higher-priority response work.
/// Returning true records local enqueue only, never delivery or authorization.
public struct V2AuthorPresentationWrite: Sendable {
    public let bytes: Data
    private let cancelPermit: @Sendable () -> Void
    private let permit: @Sendable (@Sendable () -> Void) -> Bool

    init(bytes: Data, cancel: @escaping @Sendable () -> Void, permit: @escaping @Sendable (@Sendable () -> Void) -> Bool) {
        self.bytes = bytes; self.permit = permit; self.cancelPermit = cancel
    }

    /// Keep the closure synchronous and short: enqueue these bytes exactly once.
    /// Lifecycle invalidation and enqueue are serialized by the same gate.
    package func cancel() { cancelPermit() }

    public func enqueueIfCurrent(_ enqueue: @Sendable () -> Void) -> Bool { permit(enqueue) }
}

package final class V2AuthorPresentationTransport: Sendable {
    private struct State: Sendable {
        var generation = UUID()
        var viewID: UUID?
        var roomID: RoomID?
        var deadline: ContinuousClock.Instant = .now
    }
    private let state = Mutex(State())

    package init() {}

    package func activate(viewID: UUID, roomID: RoomID? = nil) {
        state.withLock {
            guard $0.viewID != viewID else { return }
            $0.generation = UUID(); $0.viewID = viewID; $0.roomID = roomID
            $0.deadline = .now + .milliseconds(V2AuthorPresentationDelta.maximumViewAgeMilliseconds)
        }
    }
    package func deactivate() { state.withLock { $0.generation = UUID(); $0.viewID = nil } }

    package func selectedView(in roomID: RoomID) -> UUID? {
        state.withLock { $0.roomID == roomID && $0.deadline > .now ? $0.viewID : nil }
    }

    package func prepare(bytes: Data, viewID: UUID, deadline: ContinuousClock.Instant,
                 sessionIsLive: @escaping @Sendable () -> Bool) -> V2AuthorPresentationWrite? {
        guard bytes.count <= V2AuthorPresentationDelta.maximumFrameBytes else { return nil }
        let generation = state.withLock { $0.viewID == viewID ? $0.generation : nil }
        guard let generation else { return nil }
        let consumed = Mutex(false)
        return .init(bytes: bytes, cancel: { consumed.withLock { $0 = true } }) { [self] enqueue in
            state.withLock { current in
                guard current.generation == generation, current.viewID == viewID,
                      ContinuousClock.now < min(deadline, current.deadline), sessionIsLive() else { return false }
                return consumed.withLock { used in
                    guard !used else { return false }
                    used = true; enqueue(); return true
                }
            }
        }
    }
}
