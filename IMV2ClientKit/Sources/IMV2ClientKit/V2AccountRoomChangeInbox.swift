import Foundation
import IMV2Core

public enum V2AccountRoomChange: Equatable, Sendable {
    case changed(epoch: UUID, roomID: RoomID, highWatermark: UInt64)
    case resyncRequired(epoch: UUID)
}

public protocol V2AccountRoomChangeSource: Sendable {
    func nextAccountRoomChange() async throws -> V2AccountRoomChange
}

public enum V2AccountRoomChangeError: Error, Equatable, Sendable {
    case invalidNotification, wrongEpoch, sequenceGap, bufferOverflow, notStarted
}

/// Owned by the TLS connection actor. Validate every wire sequence before
/// coalescing; consumer-side coalescing never fabricates a transport gap.
struct V2AccountRoomChangeInbox: Sendable {
    private let maximumPendingRooms: Int
    private(set) var epoch: UUID?
    private var sequence: UInt64 = 0
    private var pending: [RoomID: UInt64] = [:]
    private var order: [RoomID] = []
    private var offset = 0
    private var resetPending = false
    private var invalidated = false

    init() { maximumPendingRooms = 4096 }
    init(maximumPendingRooms: Int) throws {
        guard maximumPendingRooms > 0 else { throw V2AccountRoomChangeError.invalidNotification }
        self.maximumPendingRooms = maximumPendingRooms
    }

    mutating func begin(epoch raw: String) throws {
        guard epoch == nil, let parsed = UUID(uuidString: raw) else { throw V2AccountRoomChangeError.invalidNotification }
        epoch = parsed
    }

    mutating func accept(_ change: IMV2AccountRoomChanged) throws {
        guard let epoch else { throw V2AccountRoomChangeError.notStarted }
        guard UUID(uuidString: change.connectionEpoch) == epoch else { throw V2AccountRoomChangeError.wrongEpoch }
        guard !invalidated, let uuid = UUID(uuidString: change.roomID),
              change.highWatermark <= UInt64(Int64.max) else { throw V2AccountRoomChangeError.invalidNotification }
        guard sequence < UInt64.max, change.notificationSequence == sequence + 1 else {
            throw V2AccountRoomChangeError.sequenceGap
        }
        let room = RoomID(uuid: uuid)
        if let previous = pending[room] { pending[room] = max(previous, change.highWatermark) }
        else {
            guard pending.count < maximumPendingRooms else { throw V2AccountRoomChangeError.bufferOverflow }
            pending[room] = change.highWatermark
            order.append(room)
        }
        sequence = change.notificationSequence
    }

    mutating func accept(_ reset: IMV2AccountRoomResyncRequired) throws {
        guard let epoch else { throw V2AccountRoomChangeError.notStarted }
        guard UUID(uuidString: reset.connectionEpoch) == epoch else { throw V2AccountRoomChangeError.wrongEpoch }
        guard !invalidated else { return }
        invalidated = true
        resetPending = true
        pending.removeAll(); order.removeAll(); offset = 0
    }

    mutating func next() -> V2AccountRoomChange? {
        guard let epoch else { return nil }
        if resetPending { resetPending = false; return .resyncRequired(epoch: epoch) }
        guard offset < order.count else { return nil }
        let room = order[offset]; offset += 1
        let head = pending.removeValue(forKey: room)!
        if offset >= order.count / 2 { order.removeFirst(offset); offset = 0 }
        return .changed(epoch: epoch, roomID: room, highWatermark: head)
    }
}
