import IMV2Core

/// Connection-owned bounded inbox. Different rooms never overwrite one another;
/// overflow closes the connection so durable recovery covers the missing work.
struct V2RoomEventInbox {
    private var hints: [RoomID: V2GroupEventAvailabilityHint] = [:]
    private var order: [RoomID] = []
    private var offset = 0
    private var bytes = 0
    let maximumRooms: Int
    let maximumBytes: Int
    init(maximumRooms: Int = 4096, maximumBytes: Int = 16 * 1024 * 1024) {
        precondition(maximumRooms > 0 && maximumBytes > 0)
        self.maximumRooms = maximumRooms; self.maximumBytes = maximumBytes
    }
    mutating func offer(_ hint: V2GroupEventAvailabilityHint) throws {
        let old = hints[hint.roomID]
        let merged = old.map { $0.coalescing(with: hint) } ?? hint
        let size = estimatedBytes(merged)
        let remaining = bytes - (old.map(estimatedBytes) ?? 0)
        guard old != nil || hints.count < maximumRooms,
              size <= maximumBytes, remaining <= maximumBytes - size else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        if old == nil { order.append(hint.roomID) }
        hints[hint.roomID] = merged; bytes = remaining + size
    }
    mutating func next() -> V2GroupEventAvailabilityHint? {
        guard offset < order.count else { return nil }
        let room = order[offset]; offset += 1
        let hint = hints.removeValue(forKey: room)
        if let hint { bytes -= estimatedBytes(hint) }
        if offset >= 128 && offset * 2 >= order.count {
            order.removeFirst(offset); offset = 0
        }
        return hint
    }
    private func estimatedBytes(_ hint: V2GroupEventAvailabilityHint) -> Int {
        hint.liveEvents.reduce(128) { $0 + $1.payload.count + 128 }
    }
}
