import IMV2ServerContracts
import Foundation
import IMV2Core

/// 每个房间只有一份消息代理订阅意向，供网关的不同功能共享。
/// 各作用域分别维护房间级需求，不按设备创建租约。
public actor V2SharedGroupEventWakeInterests {
    public enum Scope: Hashable, Sendable {
        case foreground
        /// 共享的在线账号生命周期，与连接数量无关。
        case account(UUID)
    }
    public struct Activation: Hashable, Sendable {
        public let roomID: RoomID
        public let scope: Scope
        public init(roomID: RoomID, scope: Scope) { self.roomID = roomID; self.scope = scope }
    }

    public enum Failure: Error, Equatable, Sendable { case closed }

    private struct Operation: Sendable {
        let id: UUID
        let task: Task<UUID, Error>
        // The room receipt joins an independent batch shared by its peers.
        let batch: Task<Void, Error>?
    }

    private final class Entry {
        var owners: [Scope: UUID] = [:]
        var revision = UUID()
        // Actual underlying demand settled by this owner. This is not a
        // coverage proof; the native coordinator restores coverage itself.
        var confirmedActive: Bool?
        var operation: Operation?
    }

    private let underlying: any V2GroupEventWakeInterestManaging
    private var entries: [RoomID: Entry] = [:]
    private var closed = false
    private var shutdownTask: Task<Void, Never>?

    public init(underlying: any V2GroupEventWakeInterestManaging) {
        self.underlying = underlying
    }

    public nonisolated func manager(for scope: Scope) -> some V2GroupEventWakeInterestManaging {
        ScopedInterest(owner: self, scope: scope)
    }

    func interestedScopes(roomID: RoomID) -> Set<Scope> {
        Set(entries[roomID]?.owners.keys.map { $0 } ?? [])
    }

    private func activate(roomID: RoomID, scope: Scope) async throws {
        try await activate([.init(roomID: roomID, scope: scope)])
    }

    public func activate(_ requests: [Activation]) async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard requests.count <= 128, Set(requests).count == requests.count else { throw V2RoomRecoveryReadError.invalidRequest }
        if requests.isEmpty { return }
        var tokens: [Activation: UUID] = [:]
        var selected: [RoomID: Entry] = [:]
        for request in requests {
            let entry = entries[request.roomID] ?? Entry()
            entries[request.roomID] = entry
            let token = UUID(); tokens[request] = token
            entry.owners[request.scope] = token; entry.revision = UUID()
            selected[request.roomID] = entry
        }
        // Join existing operations. Only idle entries join this one underlying
        // batch, so concurrent foreground demand cannot start competing SQL.
        let fresh = selected.filter { $0.value.operation == nil && $0.value.confirmedActive != true }
        if !fresh.isEmpty {
            let rooms = fresh.keys.sorted { $0.rawValue < $1.rawValue }
            let batch = Task { try await self.activateUnderlying(rooms) }
            for (room, entry) in fresh {
                let revision = entry.revision, operationID = UUID()
                entry.operation = .init(id: operationID, task: Task {
                    try await batch.value
                    return self.confirmBatchActivation(roomID: room, operationID: operationID, revision: revision)
                }, batch: batch)
            }
        }
        do {
            for room in selected.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                try await reconcile(roomID: room, entry: selected[room]!)
            }
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
        } catch {
            // A waiter owns only these tokens. Cancelling it never cancels the
            // shared registration task or removes a replacement generation.
            for (request, token) in tokens {
                guard let entry = selected[request.roomID], entry.owners[request.scope] == token else { continue }
                entry.owners.removeValue(forKey: request.scope); entry.revision = UUID()
            }
            if !closed {
                for (room, entry) in selected { try? await reconcile(roomID: room, entry: entry) }
            }
            throw error
        }
    }

    private func confirmBatchActivation(roomID: RoomID, operationID: UUID, revision: UUID) -> UUID {
        if let entry = entries[roomID], entry.operation?.id == operationID {
            entry.confirmedActive = true
        }
        return revision
    }

    private func activateUnderlying(_ rooms: [RoomID]) async throws {
        guard !closed else { throw Failure.closed }
        for room in rooms { try await underlying.activate(roomID: room) }
    }

    private func deactivate(roomID: RoomID, scope: Scope) async {
        guard !closed, let entry = entries[roomID], entry.owners.removeValue(forKey: scope) != nil else { return }
        entry.revision = UUID()
        // 其他仍存在作用域的消息代理激活失败，仍须报告给该作用域的调用方；
        // 释放我方需求不负责处理它。
        do { try await reconcile(roomID: roomID, entry: entry) }
        catch {
            // 执行中的激活即使失败，也可能在最后一个作用域移除后才结束。
            // 仍须释放消息代理端残留的部分状态。
            if !closed, entry.owners.isEmpty { try? await reconcile(roomID: roomID, entry: entry) }
        }
    }

    private func reconcile(roomID: RoomID, entry: Entry) async throws {
        while entries[roomID] === entry {
            let operation: Operation
            if let existing = entry.operation { operation = existing }
            else {
                let desired = !entry.owners.isEmpty
                if entry.confirmedActive == desired {
                    if !desired { entries.removeValue(forKey: roomID) }
                    return
                }
                operation = .init(id: UUID(), task: Task { try await self.drive(roomID: roomID, entry: entry) }, batch: nil)
                entry.operation = operation
            }
            do {
                let settledRevision = try await operation.task.value
                if entry.operation?.id == operation.id { entry.operation = nil }
                // 新调用方加入前任务可能已完成。
                // 不只检查成功与否，还要复查返回的修订号。
                if settledRevision == entry.revision {
                    if entry.operation == nil, entry.owners.isEmpty, entries[roomID] === entry {
                        entries.removeValue(forKey: roomID)
                    }
                    return
                }
            } catch {
                if entry.operation?.id == operation.id {
                    entry.operation = nil
                    entry.confirmedActive = nil // Failed I/O may have applied partial state.
                }
                throw error
            }
        }
    }

    private func drive(roomID: RoomID, entry: Entry) async throws -> UUID {
        while true {
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
            guard entries[roomID] === entry else { return entry.revision }
            let revision = entry.revision
            let desired = !entry.owners.isEmpty
            if entry.confirmedActive != desired {
                do {
                    if desired { try await underlying.activate(roomID: roomID) }
                    else { await underlying.deactivate(roomID: roomID) }
                    entry.confirmedActive = desired
                } catch {
                    entry.confirmedActive = nil
                    throw error
                }
            }
            // 任何等待者认定激活或停用完成前，
            // 都须核对消息代理 I/O 期间发生的作用域修改。
            if entry.revision == revision { return revision }
        }
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let rooms = Array(entries.keys)
        let operations = entries.values.compactMap(\.operation)
        entries.removeAll()
        for operation in operations {
            operation.batch?.cancel()
            operation.task.cancel()
        }
        let task = Task { [underlying] in
            for operation in operations { _ = try? await operation.task.value }
            for roomID in rooms { await underlying.deactivate(roomID: roomID) }
        }
        shutdownTask = task
        await task.value
    }

    private struct ScopedInterest: V2GroupEventWakeInterestManaging {
        let owner: V2SharedGroupEventWakeInterests
        let scope: Scope
        func activate(roomID: RoomID) async throws { try await owner.activate(roomID: roomID, scope: scope) }
        func deactivate(roomID: RoomID) async { await owner.deactivate(roomID: roomID, scope: scope) }
    }
}
