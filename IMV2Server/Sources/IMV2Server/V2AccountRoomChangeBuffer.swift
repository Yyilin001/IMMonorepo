import Foundation
import IMV2Core

enum V2AccountRoomNotification: Equatable, Sendable {
    case changed(epoch: UUID, sequence: UInt64, roomID: RoomID, highWatermark: UInt64)
    case resyncRequired(epoch: UUID)

    func envelope() -> IMV2Envelope {
        var envelope = IMV2Envelope()
        switch self {
        case .changed(let epoch, let sequence, let roomID, let watermark):
            envelope.accountRoomChanged.connectionEpoch = epoch.uuidString.lowercased()
            envelope.accountRoomChanged.notificationSequence = sequence
            envelope.accountRoomChanged.roomID = roomID.rawValue
            envelope.accountRoomChanged.highWatermark = watermark
        case .resyncRequired(let epoch):
            envelope.accountRoomResyncRequired.connectionEpoch = epoch.uuidString.lowercased()
        }
        return envelope
    }
}

/// Connection-owned queue; it contains no membership or authorization cache.
/// Callers must authorize offers and stop the connection when an extracted
/// frame cannot be delivered. Extraction transfers ownership to that writer.
struct V2AccountRoomChangeBuffer: Sendable {
    let epoch: UUID
    private let maximumPendingRooms: Int
    private var pending: [RoomID: UInt64] = [:]
    private var order: [RoomID] = []
    private var offset = 0
    private var sequence: UInt64 = 0
    private var phase: Phase = .accepting

    private enum Phase: Sendable { case accepting, resyncPending, invalidated }

    init(epoch: UUID, maximumPendingRooms: Int = 4096) throws {
        guard maximumPendingRooms > 0 else { throw V2RoomRecoveryReadError.invalidRequest }
        self.epoch = epoch
        self.maximumPendingRooms = maximumPendingRooms
    }

    var pendingRoomCount: Int { pending.count }
    var hasOutput: Bool { phase == .resyncPending || !pending.isEmpty }
    var requiresRestart: Bool { phase != .accepting }

    /// The limit bounds unsent changes, never the number of joined rooms.
    mutating func offer(roomID: RoomID, highWatermark: UInt64) throws {
        guard roomID.uuidValue != nil, highWatermark <= UInt64(Int64.max) else {
            throw V2RoomRecoveryReadError.invalidRequest
        }
        guard phase == .accepting else { return }
        if let previous = pending[roomID] {
            pending[roomID] = max(previous, highWatermark)
            return
        }
        guard pending.count < maximumPendingRooms else {
            invalidate()
            return
        }
        pending[roomID] = highWatermark
        order.append(roomID)
    }

    /// Remove unsent metadata without allocating a wire sequence. Remove its
    /// FIFO slot too, so a later rejoin starts behind already pending rooms.
    mutating func revoke(roomID: RoomID) {
        guard pending.removeValue(forKey: roomID) != nil else { return }
        order = order.dropFirst(offset).filter { $0 != roomID }
        offset = 0
    }

    /// Broker gaps, authorization uncertainty and overflow share an explicit
    /// recovery boundary. No more change frames are emitted in this epoch.
    mutating func invalidate() {
        guard phase == .accepting else { return }
        phase = .resyncPending
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        offset = 0
    }

    mutating func next() -> V2AccountRoomNotification? {
        if phase == .resyncPending {
            phase = .invalidated
            return .resyncRequired(epoch: epoch)
        }
        guard phase == .accepting, offset < order.count else { return nil }
        guard sequence < UInt64.max else {
            invalidate()
            return next()
        }
        let roomID = order[offset]
        offset += 1
        let watermark = pending.removeValue(forKey: roomID)!
        // FIFO is by first pending change, so a hot room cannot keep moving
        // cold rooms behind it. Compact consumed storage with amortized cost.
        if offset >= order.count / 2 {
            order.removeFirst(offset)
            offset = 0
        }
        sequence += 1
        return .changed(epoch: epoch, sequence: sequence, roomID: roomID, highWatermark: watermark)
    }
}
