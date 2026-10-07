import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import Synchronization

/// Bounded synchronous post-commit mailbox. It creates no asynchronous work;
/// its owning physical-host worker takes batches and owns repair/close/join.
/// Dropping facts only coalesces a durable repair head, never publish liability.
public final class V2RoomCommittedFactsFeed: V2CommittedMessageBatchObserving, Sendable {
    private struct Room: Sendable {
        let activation: V2RoomActivationToken
        var messages: [UInt64: V2AcceptedMessage] = [:]
        var bytes = 0
        var dirty: UInt64?
    }
    private struct State: Sendable {
        var rooms: [RoomID: Room] = [:]
        var facts = 0
        var bytes = 0
        var finished = false
    }
    private let state = Mutex(State())
    private let downstream: (any V2CommittedMessageBatchObserving)?
    private let notify: @Sendable (RoomID) -> Void
    private let maximumRooms: Int
    private let maximumFactsPerRoom: Int
    private let maximumFactsTotal: Int
    private let maximumTextBytes: Int

    public init(downstream: (any V2CommittedMessageBatchObserving)? = nil,
                notify: @escaping @Sendable (RoomID) -> Void,
                maximumRooms: Int = 8192, maximumFactsPerRoom: Int = 64,
                maximumFactsTotal: Int = 4096, maximumTextBytes: Int = 16 * 1024 * 1024) {
        precondition(maximumRooms > 0 && maximumFactsPerRoom > 0 && maximumFactsTotal > 0 && maximumTextBytes > 0)
        self.downstream = downstream; self.notify = notify; self.maximumRooms = maximumRooms
        self.maximumFactsPerRoom = maximumFactsPerRoom; self.maximumFactsTotal = maximumFactsTotal
        self.maximumTextBytes = maximumTextBytes
    }

    @discardableResult
    public func register(activation: V2RoomActivationToken) -> Bool {
        state.withLock { value in
            guard !value.finished else { return false }
            if let existing = value.rooms[activation.roomID] { return existing.activation == activation }
            guard value.rooms.count < maximumRooms else { return false }
            value.rooms[activation.roomID] = Room(activation: activation); return true
        }
    }

    public func unregister(activation: V2RoomActivationToken) {
        state.withLock { value in
            guard let room = value.rooms[activation.roomID], room.activation == activation else { return }
            value.facts -= room.messages.count; value.bytes -= room.bytes
            value.rooms.removeValue(forKey: activation.roomID)
        }
    }

    /// Advisory committed H is independent of the Owner's consumed cursor.
    /// Reading the bounded room mailbox transfers no body/repair responsibility.
    public func highWatermark(activation: V2RoomActivationToken) -> UInt64? {
        state.withLock { value in
            guard !value.finished, let room = value.rooms[activation.roomID], room.activation == activation else { return nil }
            return max(room.dirty ?? 0, room.messages.keys.max() ?? 0)
        }
    }

    /// Reading does not transfer or erase responsibility. The serialized Host
    /// acknowledges only the prefix the Owner actually consumed.
    public func take(activation: V2RoomActivationToken) -> V2RoomCommittedFactsBatch? {
        state.withLock { value in
            guard !value.finished, let room = value.rooms[activation.roomID], room.activation == activation,
                  !room.messages.isEmpty || room.dirty != nil else { return nil }
            return .init(activation: activation,
                messages: room.messages.sorted { $0.key < $1.key }.map(\.value),
                dirtyHighWatermark: room.dirty)
        }
    }

    public func acknowledge(activation: V2RoomActivationToken, consumedThrough: UInt64) {
        state.withLock { value in
            guard !value.finished, var room = value.rooms[activation.roomID], room.activation == activation else { return }
            let consumed = room.messages.filter { $0.key <= consumedThrough }
            for (sequence, message) in consumed {
                room.messages.removeValue(forKey: sequence)
                let bytes = message.text.utf8.count + 512
                room.bytes -= bytes; value.bytes -= bytes; value.facts -= 1
            }
            if let dirty = room.dirty, dirty <= consumedThrough { room.dirty = nil }
            value.rooms[activation.roomID] = room
        }
    }

    public func finish() {
        state.withLock { $0.finished = true; $0.rooms.removeAll(); $0.facts = 0; $0.bytes = 0 }
    }

    public func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) {
        downstream?.observeCommittedMessages(outcomes, activation: activation)
        let changed = state.withLock { value -> Bool in
            guard !value.finished, var room = value.rooms[activation.roomID], room.activation == activation else { return false }
            var changed = false
            for outcome in outcomes {
                guard case .accepted(let message) = outcome, message.roomID == activation.roomID else { continue }
                changed = true
                let bytes = message.text.utf8.count + 512
                let supported = message.sourceEventID != nil && message.acceptedMembershipRevision != nil
                    && message.media.isEmpty && message.mediaPresentations.isEmpty && message.mentions.isEmpty
                    && message.entities.isEmpty && message.replyTo == nil
                if let previous = room.messages[message.roomSequence] {
                    if previous != message { Self.degrade(&room, through: message.roomSequence, state: &value) }
                    continue
                }
                if room.dirty != nil || !supported || room.messages.count >= maximumFactsPerRoom
                    || value.facts >= maximumFactsTotal || bytes > maximumTextBytes
                    || value.bytes > maximumTextBytes - bytes {
                    Self.degrade(&room, through: message.roomSequence, state: &value)
                } else {
                    room.messages[message.roomSequence] = message; room.bytes += bytes
                    value.bytes += bytes; value.facts += 1
                }
            }
            value.rooms[activation.roomID] = room; return changed
        }
        if changed { notify(activation.roomID) }
    }

    public func observeCommittedRoomSequence(roomID: RoomID, roomSequence: UInt64, activation: V2RoomActivationToken) {
        downstream?.observeCommittedRoomSequence(roomID: roomID, roomSequence: roomSequence, activation: activation)
        guard roomID == activation.roomID else { return }
        markDirty(roomID: roomID, roomSequence: roomSequence, activation: activation)
    }

    private func markDirty(roomID: RoomID, roomSequence: UInt64, activation: V2RoomActivationToken) {
        let changed = state.withLock { value -> Bool in
            guard !value.finished, var room = value.rooms[roomID],
                  activation == room.activation else { return false }
            Self.degrade(&room, through: roomSequence, state: &value)
            value.rooms[roomID] = room; return true
        }
        if changed { notify(roomID) }
    }
    private static func degrade(_ room: inout Room, through sequence: UInt64, state: inout State) {
        let queuedHead = room.messages.keys.max() ?? 0
        room.dirty = max(room.dirty ?? 0, max(sequence, queuedHead))
        state.facts -= room.messages.count; state.bytes -= room.bytes
        room.messages.removeAll(keepingCapacity: true); room.bytes = 0
    }
}
