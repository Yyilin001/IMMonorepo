import IMV2ServerContracts
import Foundation
import IMV2Core

/// 每个房间只有一份消息代理订阅意向，供网关的不同功能共享。
/// 各作用域分别维护房间级需求，不按设备创建租约。
public actor V2SharedGroupEventWakeInterests {
    public enum Scope: Hashable, Sendable {
        case foreground, accountCoverage
        /// 共享的在线账号生命周期，与连接数量无关。
        case account(UUID)
    }
    public enum Failure: Error, Equatable, Sendable { case closed }

    private final class Entry {
        var owners: [Scope: UUID] = [:]
        var revision = UUID()
        var operation: (id: UUID, task: Task<UUID, Error>)?
    }

    private let underlying: any V2GroupEventWakeInterestManaging
    private var entries: [RoomID: Entry] = [:]
    private var closed = false

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
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        let entry = entries[roomID] ?? Entry()
        entries[roomID] = entry
        let token = UUID()
        entry.owners[scope] = token
        entry.revision = UUID()
        do {
            try await reconcile(roomID: roomID, entry: entry)
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
        } catch {
            // 迟到的故障不能释放此作用域中较新的激活。
            if entry.owners[scope] == token {
                entry.owners.removeValue(forKey: scope)
                entry.revision = UUID()
            }
            if !closed { try? await reconcile(roomID: roomID, entry: entry) }
            throw error
        }
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
            let operation: (id: UUID, task: Task<UUID, Error>)
            if let existing = entry.operation { operation = existing }
            else {
                operation = (UUID(), Task { try await self.drive(roomID: roomID, entry: entry) })
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
                if entry.operation?.id == operation.id { entry.operation = nil }
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
            if entry.owners.isEmpty { await underlying.deactivate(roomID: roomID) }
            else { try await underlying.activate(roomID: roomID) }
            // 任何等待者认定激活或停用完成前，
            // 都须核对消息代理 I/O 期间发生的作用域修改。
            if entry.revision == revision { return revision }
        }
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        let active = entries
        for entry in active.values { entry.operation?.task.cancel() }
        for entry in active.values { _ = try? await entry.operation?.task.value }
        for roomID in active.keys { await underlying.deactivate(roomID: roomID) }
        entries.removeAll()
    }

    private struct ScopedInterest: V2GroupEventWakeInterestManaging {
        let owner: V2SharedGroupEventWakeInterests
        let scope: Scope
        func activate(roomID: RoomID) async throws { try await owner.activate(roomID: roomID, scope: scope) }
        func deactivate(roomID: RoomID) async { await owner.deactivate(roomID: roomID, scope: scope) }
    }
}
