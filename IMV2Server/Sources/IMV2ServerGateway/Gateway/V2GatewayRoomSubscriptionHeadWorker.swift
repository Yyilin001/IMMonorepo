import Foundation
import Synchronization
import IMV2Core

/// Fixed runtime-owned consumers and one latest H per pending room. A paused
/// room never blocks another room; publications for one room remain serial.
final class V2GatewayRoomSubscriptionHeadWorker: Sendable {
    private typealias Head = (RoomID, UInt64)
    private typealias Reader = CheckedContinuation<Head?, Never>
    private struct State: Sendable {
        var heads: [RoomID: UInt64] = [:]
        var queued: Set<RoomID> = []
        var active: Set<RoomID> = []
        var order: [RoomID] = []
        var offset = 0
        var readers: [Reader] = []
        var consumer: Task<Void, Never>?
        var closed = false

        mutating func take() -> Head? {
            guard !closed, offset < order.count else { return nil }
            let room = order[offset]; offset += 1
            if offset >= 128 { order.removeFirst(offset); offset = 0 }
            queued.remove(room)
            guard let head = heads.removeValue(forKey: room) else { preconditionFailure("missing queued head") }
            precondition(active.insert(room).inserted)
            return (room, head)
        }
        mutating func wakeReaders() -> [(Reader, Head?)] {
            var wakes: [(Reader, Head?)] = []
            while !readers.isEmpty {
                if closed { wakes.append((readers.removeFirst(), nil)) }
                else if let head = take() { wakes.append((readers.removeFirst(), head)) }
                else { break }
            }
            return wakes
        }
    }
    private let state = Mutex(State())
    private let maximumRooms: Int
    private let maximumConcurrentRooms: Int
    private let publish: @Sendable (RoomID, UInt64) async -> Void
    init(maximumRooms: Int, maximumConcurrentRooms: Int = 4,
         publish: @escaping @Sendable (RoomID, UInt64) async -> Void) {
        precondition(maximumRooms > 0 && maximumConcurrentRooms > 0)
        self.maximumRooms = maximumRooms
        self.maximumConcurrentRooms = min(maximumRooms, maximumConcurrentRooms)
        self.publish = publish
    }
    private func update<T>(_ body: (inout State) -> T) -> T {
        let (result, wakes) = state.withLock { value in
            let result = body(&value)
            return (result, value.wakeReaders())
        }
        // Resuming a task can enter the runtime scheduler. Keep it outside
        // the queue lock, as with the actual publication and socket awaits.
        for (reader, head) in wakes { reader.resume(returning: head) }
        return result
    }
    func start() {
        state.withLock { value in
            guard !value.closed, value.consumer == nil else { return }
            value.consumer = Task { await self.consume() }
        }
    }
    @discardableResult
    func offer(roomID: RoomID, highWatermark: UInt64) -> Bool {
        update { value -> Bool in
            guard !value.closed, value.heads[roomID] != nil || value.heads.count < maximumRooms else { return false }
            if let old = value.heads[roomID] { value.heads[roomID] = max(old, highWatermark) }
            else { value.heads[roomID] = highWatermark }
            if !value.active.contains(roomID), value.queued.insert(roomID).inserted { value.order.append(roomID) }
            return true
        }
    }
    private func next() async -> Head? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { reader in
            update { $0.readers.append(reader) }
        }
    }
    private func consume() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<maximumConcurrentRooms {
                group.addTask {
                    while let (room, head) = await self.next() {
                        await self.publish(room, head)
                        self.update { value in
                            value.active.remove(room)
                            if !value.closed, value.heads[room] != nil, value.queued.insert(room).inserted {
                                value.order.append(room)
                            }
                        }
                    }
                }
            }
            await group.waitForAll()
        }
    }
    func shutdown() async {
        let task = update { value in
            value.closed = true; value.heads.removeAll(); value.queued.removeAll(); value.order.removeAll()
            return value.consumer
        }
        task?.cancel(); await task?.value
    }
}
