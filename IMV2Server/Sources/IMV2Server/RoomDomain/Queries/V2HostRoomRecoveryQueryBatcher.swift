import Foundation
import IMV2ActorContracts
import IMV2Core

/// 读取轮次已通过宿主对单个房间的准入。批次截止时间是原始的
/// 单调时钟聚合截止点；调用截止时间则是另行授予的端到端期限。
/// 调用方负责释放自己的轮次。
public struct V2GrantedRoomReadTurn: Sendable {
    public let token: V2RoomActivationToken
    public let actorUserID: UserID
    public let batchDeadline: ContinuousClock.Instant
    public let callDeadline: ContinuousClock.Instant

    // 只在运行时准入批准该房间后，由 IMV2Server 构造。
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

/// 每个实例只对应一个物理所有者数据库。它只合并宿主已批准的轮次，
/// 因此持有第一个房间的 SQL 围栏时，不会等待第二个房间的准入。
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
    private let databaseWorkAdmission: V2DatabaseWorkAdmissionController?
    private var pending: [Key: [Pending]] = [:]
    private var scheduled: [Key: Task<Void, Never>] = [:]
    private var generations: [Key: UUID] = [:]
    internal var scheduledKeyCount: Int { generations.count }
    internal private(set) var pendingCount = 0
    private var inFlightCount = 0

    public init(executor: V2ActorRoomQueryExecutor, configuration: Configuration,
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil) {
        self.execute = { query, tokens in try await executor.recovery(query, tokens: tokens) }
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
    }

    // 为准入和容量测试提供确定性的阶段屏障；
    // 生产构造始终提供上方受激活围栏保护的执行器。
    init(configuration: Configuration,
         databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil,
         execute: @escaping @Sendable (V2RoomRecoveryQuery, [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult) {
        self.execute = execute
        self.configuration = configuration
        self.databaseWorkAdmission = databaseWorkAdmission
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
        // 每个令牌都可编码。大小计算同时包含查询与用户包装和令牌字节；
        // 编码失败按项目过大拒绝。
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
                // 所有执行中槽位被占满时，刷新操作无法移除旧队列。
                // 应拒绝新项目，而非合并不同纪元或超出队列的数量与字节上限。
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
            // 只等待至原始的最早截止点，绝不从入队时间重新开始一个批次窗口。
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
        let sqlDeadline = live.map(\.turn.callDeadline).min()!
        Task {
            await V2RoomSQLDeadline.withSelectedDeadline(sqlDeadline) {
                await run(live, key: key)
            }
        }
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
            let deadline = items.map(\.turn.callDeadline).min()!
            let query: V2RoomRecoveryQuery = key.kind == .state ? .states(wire) : .latestVisible(wire)
            let result = try await v2WithAdmittedRoomDatabaseWork(databaseWorkAdmission,
                workClass: .interactiveRead, callerDeadline: deadline) {
                try await execute(query, tokens)
            }
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
