import Foundation
import Synchronization
import IMV2Core

/// One runtime-owned consumer and one latest H per admitted room. An ingress
/// callback never starts a task per packet, event, user or socket.
final class V2GatewayRoomSubscriptionHeadWorker: Sendable {
    private struct State: Sendable {
        var heads: [RoomID: UInt64] = [:]
        var queued: Set<RoomID> = []
        var order: [RoomID] = []
        var offset = 0
        var consumer: Task<Void, Never>?
        var closed = false
    }
    private let state = Mutex(State())
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let maximumRooms: Int
    private let publish: @Sendable (RoomID, UInt64) async -> Void
    init(maximumRooms: Int, publish: @escaping @Sendable (RoomID, UInt64) async -> Void) {
        precondition(maximumRooms > 0)
        self.maximumRooms = maximumRooms; self.publish = publish
    }
    func start() {
        state.withLock { value in
            guard !value.closed, value.consumer == nil else { return }
            value.consumer = Task { await self.consume() }
        }
    }
    @discardableResult
    func offer(roomID: RoomID, highWatermark: UInt64) -> Bool {
        let accepted = state.withLock { value -> Bool in
            guard !value.closed, value.heads[roomID] != nil || value.heads.count < maximumRooms else { return false }
            if let old = value.heads[roomID] { value.heads[roomID] = max(old, highWatermark) }
            else { value.heads[roomID] = highWatermark }
            if value.queued.insert(roomID).inserted { value.order.append(roomID) }
            return true
        }
        if accepted { signal.continuation.yield(()) }
        return accepted
    }
    private func next() -> (RoomID, UInt64)? {
        state.withLock { value in
            guard !value.closed, value.offset < value.order.count else { return nil }
            let room = value.order[value.offset]; value.offset += 1
            if value.offset >= 128 { value.order.removeFirst(value.offset); value.offset = 0 }
            value.queued.remove(room)
            // Capacity bounds pending rooms, not every room seen by this runtime.
            // A head arriving during publish owns a new queued entry.
            guard let head = value.heads.removeValue(forKey: room) else { return nil }
            return (room, head)
        }
    }
    private func consume() async {
        for await _ in signal.stream {
            while !Task.isCancelled, let (room, head) = next() { await publish(room, head) }
        }
    }
    func shutdown() async {
        let task = state.withLock { value in
            value.closed = true; value.heads.removeAll(); value.queued.removeAll(); value.order.removeAll()
            return value.consumer
        }
        signal.continuation.finish(); task?.cancel(); await task?.value
    }
}
