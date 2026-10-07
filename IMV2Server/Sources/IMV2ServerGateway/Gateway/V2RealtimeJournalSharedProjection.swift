import Foundation
import Synchronization
import IMV2Core
import IMV2ActorContracts

/// One grant map and head per room, shared by every local device. Receipts
/// certify only this synchronous local commit; socket writes remain independent.
public final class V2RealtimeJournalSharedProjection: Sendable {
    public struct Limits: Sendable {
        public let partitions: Int
        public let rooms: Int
        public let viewers: Int
        public let batchEntries: Int
        public init(partitions: Int = 256, rooms: Int = 65_536, viewers: Int = 262_144, batchEntries: Int = 128) {
            self.partitions = partitions; self.rooms = rooms; self.viewers = viewers; self.batchEntries = batchEntries
        }
    }
    private struct ControlFloor: Comparable {
        let ownerEpoch: UInt64
        let version: UInt64
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.ownerEpoch != rhs.ownerEpoch ? lhs.ownerEpoch < rhs.ownerEpoch : lhs.version < rhs.version
        }
    }
    // Mutable reference storage never escapes the mutex. Ordinary head updates
    // stage only their touched rooms, avoiding partition dictionary CoW copies.
    private final class Partition {
        var fence: V2RealtimeJournalProjectionFence
        var checkpoint: Int64?
        var minimumSnapshotCut: Int64 = 0
        let expectedRooms: Set<RoomID>
        let requestedViewers: Set<UserID>
        var rooms: [RoomID: V2RealtimeJournalRoomAuthorization] = [:]
        var controlFloors: [RoomID: ControlFloor] = [:]
        var viewerCount = 0
        var blocked = true
        init(fence: V2RealtimeJournalProjectionFence, expectedRooms: Set<RoomID>, requestedViewers: Set<UserID>) {
            self.fence = fence; self.expectedRooms = expectedRooms; self.requestedViewers = requestedViewers
        }
    }
    private struct State {
        var partitions: [V2RealtimeJournalSource: Partition] = [:]
        var roomSources: [RoomID: V2RealtimeJournalSource] = [:]
        var roomCount = 0
        var viewerCount = 0
        var requestedViewerCount = 0
    }
    private let state = Mutex(State())
    private let limits: Limits
    public init(limits: Limits = .init()) {
        precondition(limits.partitions > 0 && limits.rooms > 0 && limits.viewers > 0 && limits.batchEntries > 0)
        self.limits = limits
    }

    /// Trusted local interest installation defines the only viewers whose
    /// grants may be retained. Wire publishers cannot enlarge that set.
    @discardableResult
    public func requireSnapshot(source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence,
                                expectedRooms: Set<RoomID>, requestedViewers: Set<UserID>) -> Bool {
        state.withLock { value in
            guard valid(source), valid(fence), expectedRooms.count <= limits.rooms,
                  requestedViewers.count <= limits.viewers,
                  requestedViewers.allSatisfy({ $0.uuidValue != nil }),
                  expectedRooms.allSatisfy({ $0.uuidValue != nil }) else { return false }
            if let current = value.partitions[source], current.fence.sameGeneration(as: fence),
               current.expectedRooms == expectedRooms, current.requestedViewers == requestedViewers { return true }
            let predecessors = value.partitions.keys.filter {
                $0.sourceID == source.sourceID && $0.partitionID == source.partitionID
            }
            for old in predecessors { remove(old, from: &value) }
            guard value.partitions.count < limits.partitions,
                  value.roomSources.count + expectedRooms.count <= limits.rooms,
                  value.requestedViewerCount + requestedViewers.count <= limits.viewers,
                  expectedRooms.allSatisfy({ value.roomSources[$0] == nil }) else { return false }
            value.partitions[source] = Partition(fence: fence, expectedRooms: expectedRooms, requestedViewers: requestedViewers)
            value.requestedViewerCount += requestedViewers.count
            for room in expectedRooms { value.roomSources[room] = source }
            return true
        }
    }

    /// isCurrent validates installed source/routing tokens, exact interest
    /// generation and local monotonic deadlines; wire wall clocks confer no authority.
    public func apply(_ batch: V2RealtimeJournalProjectionBatch,
                      userControlInstalled: @Sendable (UserID, UInt64) -> Bool = { _, _ in false },
                      isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool)
        -> V2RealtimeJournalProjectionResult {
        state.withLock { value in
            guard valid(batch.source), valid(batch.fence), isCurrent(batch.source, batch.fence),
                  let partition = value.partitions[batch.source],
                  partition.fence.sameGeneration(as: batch.fence) else { return .stale }
            guard case .changes(let from, let through, let entries) = batch.payload else { return .snapshotRequired }
            guard !partition.blocked, let checkpoint = partition.checkpoint else {
                block(partition, in: &value, minimumCut: max(0, through)); return .snapshotRequired
            }
            guard from >= 0, through >= from, entries.count <= limits.batchEntries,
                  entries.allSatisfy({ $0.sequence > from && $0.sequence <= through }),
                  zip(entries, entries.dropFirst()).allSatisfy({ $0.sequence < $1.sequence }) else {
                block(partition, in: &value, minimumCut: max(0, through)); return .invalid
            }
            if through <= checkpoint { return receipt(batch, checkpoint: checkpoint, snapshot: false) }
            guard from == checkpoint else { block(partition, in: &value, minimumCut: through); return .snapshotRequired }
            var touched: [RoomID: V2RealtimeJournalRoomAuthorization] = [:]
            for entry in entries {
                switch entry.change {
                case .userControlInvalidation(let user, let version, _, _):
                    guard version > 0, version <= UInt64(Int64.max), userControlInstalled(user, version) else {
                        block(partition, in: &value, minimumCut: through); return .snapshotRequired
                    }
                case .authorization(let room):
                    guard valid(room), room.controlVersion > 0, partition.expectedRooms.contains(room.roomID),
                          Set(room.viewerMembershipRevisions.keys).isSubset(of: partition.requestedViewers) else {
                        block(partition, in: &value, minimumCut: through); return .invalid
                    }
                    let incoming = ControlFloor(ownerEpoch: room.ownerEpoch, version: room.controlVersion)
                    if let floor = partition.controlFloors[room.roomID], incoming <= floor {
                        // The current-state snapshot may already include this
                        // not-yet-published control. Never restore its old grant.
                        continue
                    }
                    observe(incoming, roomID: room.roomID, partition: partition)
                    // New control needs fresh authoritative current state. A
                    // publisher's ordinary batch is not a cold snapshot witness.
                    block(partition, in: &value, minimumCut: through); return .snapshotRequired
                case .controlInvalidation(let roomID, let ownerEpoch, let version):
                    guard partition.expectedRooms.contains(roomID), ownerEpoch <= UInt64(Int64.max), version > 0, version <= UInt64(Int64.max) else {
                        block(partition, in: &value, minimumCut: through); return .invalid
                    }
                    let incoming = ControlFloor(ownerEpoch: ownerEpoch, version: version)
                    if let floor = partition.controlFloors[roomID], incoming <= floor { continue }
                    observe(incoming, roomID: roomID, partition: partition)
                    block(partition, in: &value, minimumCut: through); return .snapshotRequired
                case .head(let roomID, let head, let ownerEpoch, let permissionVersion):
                    guard head <= UInt64(Int64.max), let old = touched[roomID] ?? partition.rooms[roomID],
                          old.ownerEpoch == ownerEpoch, old.permissionVersion == permissionVersion,
                          partition.controlFloors[roomID] == ControlFloor(ownerEpoch: ownerEpoch, version: permissionVersion) else {
                        if partition.expectedRooms.contains(roomID), ownerEpoch <= UInt64(Int64.max),
                           permissionVersion > 0, permissionVersion <= UInt64(Int64.max) {
                            observe(.init(ownerEpoch: ownerEpoch, version: permissionVersion), roomID: roomID, partition: partition)
                        }
                        block(partition, in: &value, minimumCut: through); return .snapshotRequired
                    }
                    touched[roomID] = .init(roomID: roomID, ownerEpoch: ownerEpoch,
                        permissionVersion: permissionVersion, controlVersion: old.controlVersion,
                        viewerMembershipRevisions: old.viewerMembershipRevisions, highWatermark: max(head, old.highWatermark))
                case .invalidate(let roomID):
                    guard partition.expectedRooms.contains(roomID) else {
                        block(partition, in: &value, minimumCut: through); return .invalid
                    }
                    // Unversioned invalidation cannot be safely ignored as an
                    // old control, so conservatively block until cold recovery.
                    block(partition, in: &value, minimumCut: through); return .snapshotRequired
                }
            }
            guard isCurrent(batch.source, batch.fence) else {
                block(partition, in: &value, minimumCut: through); return .stale
            }
            // Heads never change grants or capacity. O(batch entries), with no
            // scan of other rooms, partitions or viewer maps under this mutex.
            for (roomID, room) in touched { partition.rooms[roomID] = room }
            partition.checkpoint = through; partition.fence = batch.fence
            return receipt(batch, checkpoint: through, snapshot: false)
        }
    }

    /// Independent dirty heads can be acknowledged only after their matching
    /// control has been installed. This never advances the journal checkpoint.
    public func applyHeads(_ batch: V2RealtimeJournalProjectionBatch,
        isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool)
        -> V2RealtimeJournalProjectionResult {
        state.withLock { value in
            guard valid(batch.source), valid(batch.fence), isCurrent(batch.source, batch.fence),
                  let partition = value.partitions[batch.source],
                  partition.fence.sameGeneration(as: batch.fence) else { return .stale }
            guard case .heads(let heads) = batch.payload else { return .invalid }
            guard !partition.blocked, partition.checkpoint != nil else { return .snapshotRequired }
            guard !heads.isEmpty, heads.count <= limits.batchEntries else { return .invalid }
            var touched: [RoomID: V2RealtimeJournalRoomAuthorization] = [:]
            for head in heads {
                guard head.roomID.uuidValue != nil, head.highWatermark <= UInt64(Int64.max),
                      head.ownerEpoch <= UInt64(Int64.max),
                      head.controlVersion <= UInt64(Int64.max),
                      partition.expectedRooms.contains(head.roomID) else { return .invalid }
                let floor = ControlFloor(ownerEpoch: head.ownerEpoch, version: head.controlVersion)
                guard let room = touched[head.roomID] ?? partition.rooms[head.roomID],
                      room.ownerEpoch == head.ownerEpoch, room.permissionVersion == head.controlVersion,
                      partition.controlFloors[head.roomID] == floor else {
                    observe(floor, roomID: head.roomID, partition: partition)
                    block(partition, in: &value); return .snapshotRequired
                }
                touched[head.roomID] = .init(roomID: head.roomID, ownerEpoch: head.ownerEpoch,
                    permissionVersion: room.permissionVersion, controlVersion: room.controlVersion,
                    viewerMembershipRevisions: room.viewerMembershipRevisions,
                    highWatermark: max(room.highWatermark, head.highWatermark))
            }
            guard isCurrent(batch.source, batch.fence) else { block(partition, in: &value); return .stale }
            for (roomID, room) in touched { partition.rooms[roomID] = room }
            partition.fence = batch.fence
            return .headsApplied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence))
        }
    }

    /// Installs each room's independent current control floor together with its
    /// grants and H. The journal cut can precede those already committed controls.
    public func installAuthoritativeSnapshot(_ batch: V2RealtimeJournalProjectionBatch,
        expectedCut: Int64,
        authorizesSnapshot: @Sendable (V2RealtimeJournalProjectionBatch) -> Bool,
        isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool)
        -> V2RealtimeJournalProjectionResult {
        state.withLock { value in
            guard valid(batch.source), valid(batch.fence), isCurrent(batch.source, batch.fence), authorizesSnapshot(batch),
                  let partition = value.partitions[batch.source],
                  partition.fence.sameGeneration(as: batch.fence) else { return .stale }
            guard case .snapshot(let cut, let rooms) = batch.payload,
                  cut >= partition.minimumSnapshotCut, cut == expectedCut,
                  partition.checkpoint.map({ cut >= $0 }) ?? true,
                  rooms.count <= limits.rooms, rooms.allSatisfy(valid),
                  Set(rooms.map(\.roomID)).count == rooms.count,
                  Set(rooms.map(\.roomID)) == partition.expectedRooms else {
                block(partition, in: &value); return .snapshotRequired
            }
            var newRooms: [RoomID: V2RealtimeJournalRoomAuthorization] = [:]
            var floors: [RoomID: ControlFloor] = [:]
            var viewers = 0
            for room in rooms {
                let floor = ControlFloor(ownerEpoch: room.ownerEpoch, version: room.controlVersion)
                guard Set(room.viewerMembershipRevisions.keys).isSubset(of: partition.requestedViewers),
                      partition.controlFloors[room.roomID].map({ floor >= $0 }) ?? true else {
                    block(partition, in: &value); return .snapshotRequired
                }
                newRooms[room.roomID] = room; floors[room.roomID] = floor
                viewers += room.viewerMembershipRevisions.count
            }
            let nextRooms = value.roomCount - partition.rooms.count + newRooms.count
            let nextViewers = value.viewerCount - partition.viewerCount + viewers
            guard nextRooms <= limits.rooms, nextViewers <= limits.viewers else {
                block(partition, in: &value); return .overloaded
            }
            guard isCurrent(batch.source, batch.fence), authorizesSnapshot(batch) else {
                block(partition, in: &value); return .stale
            }
            partition.rooms = newRooms; partition.controlFloors = floors; partition.viewerCount = viewers
            value.roomCount = nextRooms; value.viewerCount = nextViewers
            partition.checkpoint = cut; partition.blocked = false; partition.fence = batch.fence
            return receipt(batch, checkpoint: cut, snapshot: true)
        }
    }

    public func invalidate(source: V2RealtimeJournalSource) {
        state.withLock { value in
            if let partition = value.partitions[source] { block(partition, in: &value) }
        }
    }
    public func remove(source: V2RealtimeJournalSource) { state.withLock { remove(source, from: &$0) } }
    public func room(_ roomID: RoomID,
                     isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool)
        -> V2RealtimeJournalRoomAuthorization? {
        state.withLock { value in
            guard let source = value.roomSources[roomID], let partition = value.partitions[source],
                  !partition.blocked, isCurrent(source, partition.fence) else { return nil }
            return partition.rooms[roomID]
        }
    }
    public func roomSnapshot(_ roomID: RoomID,
        isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool)
        -> (source: V2RealtimeJournalSource, fence: V2RealtimeJournalProjectionFence, room: V2RealtimeJournalRoomAuthorization)? {
        state.withLock { value in
            guard let source = value.roomSources[roomID], let partition = value.partitions[source],
                  !partition.blocked, isCurrent(source, partition.fence), let room = partition.rooms[roomID] else { return nil }
            return (source, partition.fence, room)
        }
    }

    public func controlCheckpoint(source: V2RealtimeJournalSource,
        isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool) -> Int64? {
        state.withLock { value in
            guard let partition = value.partitions[source], !partition.blocked,
                  isCurrent(source, partition.fence) else { return nil }
            return partition.checkpoint
        }
    }

    public func metrics() -> (partitions: Int, rooms: Int, viewers: Int) {
        state.withLock { ($0.partitions.count, $0.roomCount, $0.viewerCount) }
    }
    /// Real socket-owner enqueue runs inside the same grant mutex as control
    /// invalidation. Callers must use binding-lock -> projection-lock order;
    /// neither isCurrent nor enqueue may reenter this projection or await.
    public func withAuthorizedRoom(_ roomID: RoomID, userID: UserID,
        expectedMemberRevision: UInt64? = nil,
        isCurrent: @Sendable (V2RealtimeJournalSource, V2RealtimeJournalProjectionFence) -> Bool,
        enqueue: @Sendable () -> Void) -> Bool {
        state.withLock { value in
            guard let source = value.roomSources[roomID], let partition = value.partitions[source],
                  !partition.blocked, isCurrent(source, partition.fence),
                  let room = partition.rooms[roomID],
                  let revision = room.viewerMembershipRevisions[userID],
                  expectedMemberRevision.map({ $0 == revision }) ?? true else { return false }
            enqueue()
            return true
        }
    }
    private func observe(_ floor: ControlFloor, roomID: RoomID, partition: Partition) {
        if partition.controlFloors[roomID].map({ floor > $0 }) ?? true { partition.controlFloors[roomID] = floor }
    }
    private func block(_ partition: Partition, in value: inout State, minimumCut: Int64 = 0) {
        partition.minimumSnapshotCut = max(partition.minimumSnapshotCut, minimumCut)
        partition.blocked = true
        value.roomCount -= partition.rooms.count; value.viewerCount -= partition.viewerCount
        partition.rooms.removeAll(); partition.viewerCount = 0
        // Floors survive gaps, revoked grants and retries. Only a trusted new
        // source/interest installation can replace this ownership generation.
    }
    private func remove(_ source: V2RealtimeJournalSource, from value: inout State) {
        guard let partition = value.partitions.removeValue(forKey: source) else { return }
        value.roomCount -= partition.rooms.count; value.viewerCount -= partition.viewerCount
        value.requestedViewerCount -= partition.requestedViewers.count
        for room in partition.expectedRooms where value.roomSources[room] == source { value.roomSources.removeValue(forKey: room) }
    }
    private func valid(_ source: V2RealtimeJournalSource) -> Bool {
        !source.sourceID.isEmpty && source.sourceID.utf8.count <= 128 && (0..<256).contains(source.partitionID)
    }
    private func valid(_ fence: V2RealtimeJournalProjectionFence) -> Bool {
        fence.sourceLeaseEpoch > 0 && fence.routingPartitionEpoch > 0 && fence.interestGeneration > 0
    }
    private func valid(_ room: V2RealtimeJournalRoomAuthorization) -> Bool {
        room.roomID.uuidValue != nil && room.ownerEpoch <= UInt64(Int64.max)
            && room.controlVersion <= UInt64(Int64.max)
            // This stage uses the independently persisted room control version
            // as its permission version; no second unbacked version is invented.
            && room.permissionVersion == room.controlVersion
            && room.highWatermark <= UInt64(Int64.max) && room.viewerMembershipRevisions.count <= limits.viewers
            && room.viewerMembershipRevisions.allSatisfy { $0.key.uuidValue != nil && $0.value > 0 && $0.value <= UInt64(Int64.max) }
    }
    private func receipt(_ batch: V2RealtimeJournalProjectionBatch, checkpoint: Int64, snapshot: Bool) -> V2RealtimeJournalProjectionResult {
        .applied(.init(batchID: batch.batchID, source: batch.source, fence: batch.fence,
                       appliedThrough: checkpoint, snapshotInstalled: snapshot))
    }
}
