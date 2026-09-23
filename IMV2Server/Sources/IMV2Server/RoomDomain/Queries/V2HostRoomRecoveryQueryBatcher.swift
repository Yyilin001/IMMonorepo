import Foundation
import IMV2ActorContracts
import IMV2Core

/// A read turn has already passed host admission for exactly one room. The
/// batch deadline is the original monotonic batching cutoff; the call deadline
/// is the separately granted end-to-end deadline. The caller releases its turn.
public struct V2GrantedRoomReadTurn: Sendable {
    public let token: V2RoomActivationToken
    public let actorUserID: UserID
    public let batchDeadline: ContinuousClock.Instant
    public let callDeadline: ContinuousClock.Instant

    // Construct only in IMV2Server after runtime admission grants this room.
    init(token: V2RoomActivationToken, actorUserID: UserID,
         batchDeadline: ContinuousClock.Instant, callDeadline: ContinuousClock.Instant) {
        self.token = token
        self.actorUserID = actorUserID
        self.batchDeadline = batchDeadline
        self.callDeadline = callDeadline
    }
}

public enum V2HostRoomRecoveryBatchError: Error, Equatable, Sendable {
    case busy
    case oversized
    case deadlineExceeded
    case corruptResult
}

/// One instance belongs to one physical owner database. It only groups turns
/// already granted by the host, so it never waits for admission to a second
/// room while the first room's SQL fence is held.
public actor V2HostRoomRecoveryQueryBatcher {
    public struct Configuration: Sendable, Equatable {
        public let maximumItems: Int
        public let maximumBytes: Int
        public let maximumResponseBytes: Int
        public let maximumPendingItems: Int
        public let maximumInFlightBatches: Int

        public init(maximumItems: Int = 100, maximumBytes: Int = 64 * 1024,
                    maximumResponseBytes: Int = 256 * 1024,
                    maximumPendingItems: Int = 400, maximumInFlightBatches: Int = 4) throws {
            guard (1...100).contains(maximumItems), (256...1_048_576).contains(maximumBytes),
                  (1_024...4_194_304).contains(maximumResponseBytes),
                  maximumPendingItems >= maximumItems, maximumPendingItems <= 10_000,
                  (1...64).contains(maximumInFlightBatches) else {
                throw V2ActorContractError.invalidConfiguration("room recovery query batcher")
            }
            self.maximumItems = maximumItems
            self.maximumBytes = maximumBytes
            self.maximumResponseBytes = maximumResponseBytes
            self.maximumPendingItems = maximumPendingItems
            self.maximumInFlightBatches = maximumInFlightBatches
        }
    }

    private enum Kind: Hashable, Sendable { case state, latestVisible }
    private struct Key: Hashable, Sendable {
        let userID: UserID
        let kind: Kind
    }
    private enum Value: Sendable {
        case state(V2RoomStateReadResult)
        case latestVisible(V2RoomLatestVisibleResult)
    }
    private struct Pending: Sendable {
        let id: UUID
        let turn: V2GrantedRoomReadTurn
        let byteCount: Int
        let continuation: CheckedContinuation<Value, any Error>
    }

    private let execute: @Sendable (V2RoomRecoveryQuery, [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult
    private let configuration: Configuration
    private var pending: [Key: [Pending]] = [:]
    private var scheduled: [Key: Task<Void, Never>] = [:]
    private var generations: [Key: UUID] = [:]
    internal var scheduledKeyCount: Int { generations.count }
    internal private(set) var pendingCount = 0
    private var inFlightCount = 0

    public init(executor: V2ActorRoomQueryExecutor, configuration: Configuration) {
        self.execute = { query, tokens in try await executor.recovery(query, tokens: tokens) }
        self.configuration = configuration
    }

    // Deterministic phase barriers for admission/capacity tests; production
    // construction always supplies the activation-fenced executor above.
    init(configuration: Configuration,
         execute: @escaping @Sendable (V2RoomRecoveryQuery, [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult) {
        self.execute = execute
        self.configuration = configuration
    }

    public func state(_ turn: V2GrantedRoomReadTurn) async throws -> V2RoomStateReadResult {
        guard case .state(let result) = try await accept(turn, kind: .state) else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        return result
    }

    public func latestVisible(_ turn: V2GrantedRoomReadTurn) async throws -> V2RoomLatestVisibleResult {
        guard case .latestVisible(let result) = try await accept(turn, kind: .latestVisible) else {
            throw V2HostRoomRecoveryBatchError.corruptResult
        }
        return result
    }

    private func accept(_ turn: V2GrantedRoomReadTurn, kind: Kind) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(.init(id: id, turn: turn, byteCount: encodedByteCount(turn),
                    continuation: continuation), kind: kind)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func encodedByteCount(_ turn: V2GrantedRoomReadTurn) -> Int {
        // Every token is Codable. Include the query/user wrapper as well as
        // token bytes; a failed encode is rejected as an oversized item.
        guard let tokenBytes = try? JSONEncoder().encode(turn.token) else { return Int.max }
        return tokenBytes.count + turn.actorUserID.rawValue.utf8.count + 64
    }

    private func enqueue(_ item: Pending, kind: Kind) {
        let key = Key(userID: item.turn.actorUserID, kind: kind)
        guard !Task.isCancelled else { item.continuation.resume(throwing: CancellationError()); return }
        guard item.turn.callDeadline > .now else {
            item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.deadlineExceeded); return
        }
        guard item.byteCount <= configuration.maximumBytes else {
            item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.oversized); return
        }
        guard pendingCount < configuration.maximumPendingItems else {
            item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.busy); return
        }
        if let queued = pending[key], !queued.isEmpty {
            let differentEpoch = queued.contains {
                $0.turn.token.roomID == item.turn.token.roomID && $0.turn.token != item.turn.token
            }
            let overLimit = queued.count >= configuration.maximumItems ||
                queued.reduce(0, { $0 + $1.byteCount }) + item.byteCount > configuration.maximumBytes
            if differentEpoch || overLimit {
                // flush cannot remove the old queue when every in-flight slot
                // is occupied. Reject the new item rather than merge epochs
                // or exceed the queue's item/byte limits.
                guard inFlightCount < configuration.maximumInFlightBatches else {
                    item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.busy)
                    return
                }
                flush(key)
            }
        }
        pending[key, default: []].append(item)
        pendingCount += 1
        if pending[key]!.count >= configuration.maximumItems || item.turn.batchDeadline <= .now { flush(key) }
        else { schedule(key) }
    }

    private func schedule(_ key: Key) {
        guard pending[key]?.isEmpty == false else { return }
        scheduled[key]?.cancel()
        let generation = UUID()
        generations[key] = generation
        let deadline = pending[key]!.map { min($0.turn.batchDeadline, $0.turn.callDeadline) }.min()!
        scheduled[key] = Task {
            // Wait only until the original earliest cutoff; never create a
            // fresh batching window from the enqueue time.
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            flushIfCurrent(key, generation: generation)
        }
    }

    private func scheduleCallDeadline(_ key: Key) {
        guard let queue = pending[key], let deadline = queue.map(\.turn.callDeadline).min() else { return }
        scheduled[key]?.cancel()
        let generation = UUID()
        generations[key] = generation
        scheduled[key] = Task {
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            flushIfCurrent(key, generation: generation)
        }
    }

    private func flushIfCurrent(_ key: Key, generation: UUID) {
        guard generations[key] == generation else { return }
        flush(key)
    }

    private func flush(_ key: Key) {
        scheduled.removeValue(forKey: key)?.cancel()
        generations.removeValue(forKey: key)
        guard let queue = pending[key], !queue.isEmpty else { return }
        let now = ContinuousClock.now
        let live = queue.filter { item in
            if item.turn.callDeadline <= now {
                item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.deadlineExceeded)
                pendingCount -= 1
                return false
            }
            return true
        }
        pending[key] = live.isEmpty ? nil : live
        guard !live.isEmpty else { return }
        guard inFlightCount < configuration.maximumInFlightBatches else {
            scheduleCallDeadline(key)
            return
        }
        pending[key] = nil
        pendingCount -= live.count
        inFlightCount += 1
        Task { await run(live, key: key) }
    }

    private func run(_ items: [Pending], key: Key) async {
        do {
            let roomIDs = Array(Set(items.map { $0.turn.token.roomID }))
            let tokens = try roomIDs.map { room -> V2RoomActivationToken in
                guard let token = items.first(where: { $0.turn.token.roomID == room })?.turn.token else {
                    throw V2HostRoomRecoveryBatchError.corruptResult
                }
                return token
            }
            let wire = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: roomIDs, actorUserID: key.userID)
            let result = try await execute(key.kind == .state ? .states(wire) : .latestVisible(wire), tokens)
            guard let resultBytes = try? JSONEncoder().encode(result).count else {
                throw V2HostRoomRecoveryBatchError.corruptResult
            }
            guard resultBytes <= configuration.maximumResponseBytes else {
                throw V2HostRoomRecoveryBatchError.oversized
            }
            switch (key.kind, result) {
            case (.state, .states(let batch)):
                let values = try batch.domainValue(expectedRoomIDs: roomIDs)
                let outputs = try items.map { item -> Value in
                    guard let value = values[item.turn.token.roomID] else { throw V2HostRoomRecoveryBatchError.corruptResult }
                    return .state(value)
                }
                for (item, value) in zip(items, outputs) {
                    complete(item, value: value)
                }
            case (.latestVisible, .latestVisible(let batch)):
                let values = try batch.domainValue(expectedRoomIDs: roomIDs)
                let outputs = try items.map { item -> Value in
                    guard let value = values[item.turn.token.roomID] else { throw V2HostRoomRecoveryBatchError.corruptResult }
                    return .latestVisible(value)
                }
                for (item, value) in zip(items, outputs) {
                    complete(item, value: value)
                }
            case (_, .failure(let error)):
                for item in items { item.continuation.resume(throwing: error.domainValue()) }
            default:
                throw V2HostRoomRecoveryBatchError.corruptResult
            }
        } catch {
            for item in items { item.continuation.resume(throwing: error) }
        }
        inFlightCount -= 1
        for queuedKey in Array(pending.keys) { flush(queuedKey) }
    }

    private func complete(_ item: Pending, value: Value) {
        if item.turn.callDeadline <= .now {
            item.continuation.resume(throwing: V2HostRoomRecoveryBatchError.deadlineExceeded)
        } else {
            item.continuation.resume(returning: value)
        }
    }

    private func cancel(_ id: UUID) {
        for key in Array(pending.keys) {
            guard var queue = pending[key], let index = queue.firstIndex(where: { $0.id == id }) else { continue }
            let item = queue.remove(at: index)
            pendingCount -= 1
            item.continuation.resume(throwing: CancellationError())
            pending[key] = queue.isEmpty ? nil : queue
            if queue.isEmpty {
                scheduled.removeValue(forKey: key)?.cancel()
                generations.removeValue(forKey: key)
            }
            else { schedule(key) }
            return
        }
    }
}
