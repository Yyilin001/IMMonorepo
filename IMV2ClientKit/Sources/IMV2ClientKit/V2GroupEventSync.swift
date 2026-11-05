import Foundation
import IMV2Core

/// 房间日志的一条投影事件；序列必须为正且能作为本地房间游标持久化。
public struct V2ClientGroupEvent: Equatable, Sendable {
    /// 事件源身份。
    public let sourceEventID: EventID
    /// 用经过范围验证的房间游标保存协议整数。
    private let roomSequenceValue: V2RoomCursor
    /// 正的房间事件序列。
    public var roomSequence: UInt64 { roomSequenceValue.rawValue }
    /// 投影类型名称，此构造不检查是否为空。
    public let projectionKind: String
    /// 原始投影载荷，此构造不检查内容。
    public let payload: Data

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - sourceEventID: 事件源身份。
    ///   - roomSequence: 正的房间事件序列。
    ///   - projectionKind: 投影类型名称，此构造不检查是否为空。
    ///   - payload: 原始投影载荷，此构造不检查内容。
    /// - Throws: 房间序列超范围或为零时抛出错误。
    public init(sourceEventID: EventID, roomSequence: UInt64, projectionKind: String, payload: Data) throws {
        guard let cursor = try? V2RoomCursor(roomSequence) else { throw V2ClientSyncError.storageRangeExceeded }
        guard roomSequence > 0 else { throw V2ClientSyncError.invalidRecordOrdering }
        self.sourceEventID = sourceEventID
        self.roomSequenceValue = cursor
        self.projectionKind = projectionKind
        self.payload = payload
    }
}

/// 房间日志页面与继续水位；构造只检查游标范围，页面顺序和归属由传输及存储进一步验证。
public struct V2ClientGroupEventPage: Equatable, Sendable {
    /// 页面所属房间。
    public let roomID: RoomID
    /// 待应用的事件序列。
    public let events: [V2ClientGroupEvent]
    /// 用经过范围验证的房间游标保存协议整数。
    private let nextRoomSequenceValue: V2RoomCursor
    /// 后续拉取水位，允许零。
    public var nextRoomSequence: UInt64 { nextRoomSequenceValue.rawValue }
    /// 服务端是否声明仍有后续日志。
    public let hasMore: Bool
    /// 已裁剪的历史下界：该序号之前的事件已被服务端按保留窗口移除。
    ///
    /// 本地游标低于它时，该房间必须被标记为"历史不完整"，而不是静默地少几条。
    /// 零表示服务端从未裁剪该房间。
    public let logTrimmedThroughRoomSequence: UInt64

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - roomID: 页面所属房间。
    ///   - events: 待应用的事件序列。
    ///   - nextRoomSequence: 后续拉取水位，允许零。
    ///   - hasMore: 服务端是否声明仍有后续日志。
    ///   - logTrimmedThroughRoomSequence: 已裁剪的历史下界，允许零。
    /// - Throws: 继续水位超出可持久化范围时抛出错误；不校验事件列表。
    public init(
        roomID: RoomID,
        events: [V2ClientGroupEvent],
        nextRoomSequence: UInt64,
        hasMore: Bool,
        logTrimmedThroughRoomSequence: UInt64 = 0
    ) throws {
        guard let cursor = try? V2RoomCursor(nextRoomSequence),
              logTrimmedThroughRoomSequence <= UInt64(Int64.max)
        else { throw V2ClientSyncError.storageRangeExceeded }
        self.roomID = roomID
        self.events = events
        self.nextRoomSequenceValue = cursor
        self.hasMore = hasMore
        self.logTrimmedThroughRoomSequence = logTrimmedThroughRoomSequence
    }
}

/// 单页处理结果。可靠日志路径报告本事务新增条数；前台预览路径报告收到的页面条数，可能包含重放。
public struct V2GroupEventSyncProgress: Equatable, Sendable {
    /// 可靠路径为新增条数，预览路径为页面条数。
    public let appliedEventCount: Int
    /// 本次页面是否声明还有更多事件。
    public let hasMore: Bool

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - appliedEventCount: 可靠路径为新增条数，预览路径为页面条数。
    ///   - hasMore: 本次页面是否声明还有更多事件。
    ///
    /// 初始化仅保存字段，不执行额外范围或状态一致性校验。
    public init(appliedEventCount: Int, hasMore: Bool) {
        self.appliedEventCount = appliedEventCount
        self.hasMore = hasMore
    }
}

/// 本地页面事务提交后的水位和新增事件数，不把完全相同的重放计为新增。
public struct V2GroupEventPageCommit: Equatable, Sendable {
    /// 用经过范围验证的房间游标保存协议整数。
    private let appliedThroughValue: V2RoomCursor
    /// 事务提交后的房间水位。
    public var appliedThrough: UInt64 { appliedThroughValue.rawValue }
    /// 本次事务真正插入的事件数，排除完全相同的重放。
    public let insertedEventCount: Int
    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - appliedThrough: 事务提交后的房间水位。
    ///   - insertedEventCount: 本次事务真正插入的事件数，排除完全相同的重放。
    /// - Throws: 水位超范围或新增条数为负时抛出错误。
    public init(appliedThrough: UInt64, insertedEventCount: Int) throws {
        guard let cursor = try? V2RoomCursor(appliedThrough) else { throw V2ClientSyncError.storageRangeExceeded }
        guard insertedEventCount >= 0 else { throw V2ClientSyncError.invalidRecordOrdering }
        self.appliedThroughValue = cursor
        self.insertedEventCount = insertedEventCount
    }
}

/// 读取获授权房间日志页面的网络边界，不负责本地投影提交。
public protocol V2ClientGroupEventTransport: Sendable {
    /// 从给定房间水位之后拉取一页事件，调用者提供页大小预算；失败抛出传输或服务端错误。
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage
    func pullGroupEventPages(_ requests: [V2ClientGroupEventPull]) async throws -> [RoomID: V2ClientGroupEventPageResult]
}

public struct V2ClientGroupEventPull: Sendable {
    public let roomID: RoomID
    public let afterRoomSequence: UInt64
    public let pageSize: Int
    public init(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) {
        self.roomID = roomID; self.afterRoomSequence = afterRoomSequence; self.pageSize = pageSize
    }
}

public enum V2ClientGroupEventPageResult: Sendable {
    case page(V2ClientGroupEventPage)
    case failure(V2RealtimeTransportError)
}

extension V2ClientGroupEventTransport {
    // Local adapters can retain the single-page contract. The production
    // protobuf transport implements the bounded wire batch directly.
    public func pullGroupEventPages(_ requests: [V2ClientGroupEventPull]) async throws -> [RoomID: V2ClientGroupEventPageResult] {
        guard (1...16).contains(requests.count), Set(requests.map(\.roomID)).count == requests.count else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        return try await withThrowingTaskGroup(of: (RoomID, V2ClientGroupEventPageResult).self) { group in
            func submit(_ request: V2ClientGroupEventPull) {
                group.addTask {
                    try Task.checkCancellation()
                    do { return (request.roomID, .page(try await self.pullGroupEvents(roomID: request.roomID,
                        afterRoomSequence: request.afterRoomSequence, pageSize: request.pageSize))) }
                    catch let error as V2RealtimeTransportError { return (request.roomID, .failure(error)) }
                }
            }
            var next = requests.makeIterator()
            for _ in 0..<min(4, requests.count) { if let request = next.next() { submit(request) } }
            var result: [RoomID: V2ClientGroupEventPageResult] = [:]
            while let (room, page) = try await group.next() {
                result[room] = page
                if let request = next.next() { submit(request) }
            }
            return result
        }
    }
}

/// 房间事件订阅确认的高水位摘要，不表示该范围的事件已经下载或应用。
public struct V2ClientGroupEventSubscription: Equatable, Sendable {
    /// 已订阅房间。
    public let roomID: RoomID
    /// 用经过范围验证的房间游标保存协议整数。
    private let highWatermarkValue: V2RoomCursor
    /// 服务端报告的当前房间高水位，允许零。
    public var highWatermark: UInt64 { highWatermarkValue.rawValue }

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - roomID: 已订阅房间。
    ///   - highWatermark: 服务端报告的当前房间高水位，允许零。
    /// - Throws: 高水位超出可持久化范围时抛出错误。
    public init(roomID: RoomID, highWatermark: UInt64) throws {
        guard let cursor = try? V2RoomCursor(highWatermark) else { throw V2ClientSyncError.storageRangeExceeded }
        self.roomID = roomID
        self.highWatermarkValue = cursor
    }
}

/// 本地房间日志的当前访问权限。
public struct V2ClientGroupEventAccess: Equatable, Sendable {
    /// 当前本地状态是否允许读取。
    public let isAuthorized: Bool

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - isAuthorized: 当前本地状态是否允许读取。
    ///
    /// 初始化仅保存字段，不执行额外范围或状态一致性校验。
    public init(isAuthorized: Bool) {
        self.isAuthorized = isAuthorized
    }
}

/// 前台事件订阅控制，与持久化事件读取分离；唤醒或订阅确认不能当作消息已送达。
public protocol V2ClientGroupEventSubscriptionTransport: Sendable {
    /// 订阅房间事件通知并返回高水位；订阅结果不是持久化投递确认，失败通过错误报告。
    func subscribeToGroupEvents(roomID: RoomID, afterRoomSequence: UInt64) async throws -> V2ClientGroupEventSubscription
    /// 取消房间事件订阅，失败通过错误报告。
    func unsubscribeFromGroupEvents(roomID: RoomID) async throws
}

/// 可靠房间日志的本地事务边界。
///
/// 每页投影与房间游标必须在同一事务提交；全账号发现和公平调度由恢复引擎负责。
public protocol V2LocalGroupEventStore: Sendable {
    /// 读取该房间已持久化的事件水位，供下次拉取使用；读取或状态错误通过抛出报告。
    func groupEventCursor(roomID: RoomID) async throws -> UInt64
    /// 验证并原子应用事件页及其房间游标，返回提交水位；失败不能只推进游标而遗漏投影。
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) async throws -> UInt64
    /// 原子提交事件页与游标，并报告本事务新增条数，排除精确重放；失败通过存储或校验错误报告。
    func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) async throws -> V2GroupEventPageCommit
}

/// 按房间串行执行完整的读游标、拉取与应用流程。
///
/// 同一房间的并发调用等待旧任务结束后各自读取下一页，不共享旧结果。不同房间可以并发处理，
/// 本地存储负责把每页投影与游标原子提交，避免崩溃后跳过事件。
public actor V2GroupEventSyncEngine {
    /// 读取群事件页的传输依赖。
    private let transport: any V2ClientGroupEventTransport
    /// 按本引擎可靠或预览合同应用事件的存储依赖。
    private let store: any V2LocalGroupEventStore
    /// 每次网络拉取的页面预算。
    private let pageSize: Int

    /// 配置事件读取与本地应用依赖，不在初始化时启动同步。
    ///
    /// - Parameters:
    ///   - transport: 群事件传输。
    ///   - store: 对应的本地存储实现。
    ///   - pageSize: 单页预算，默认 200，必须大于零且不超过 500。
    ///
    /// 页大小无效时触发前置条件失败。
    public init(transport: any V2ClientGroupEventTransport, store: any V2LocalGroupEventStore, pageSize: Int = 200) {
        precondition(pageSize > 0 && pageSize <= V2GroupEventLogLimits.maximumPageSize)
        self.transport = transport
        self.store = store
        self.pageSize = pageSize
    }

    /// 单个房间正在执行的完整页面任务及其身份，用于在 await 之后安全清理任务记录。
    private struct PageFlight {
        /// 任务唯一身份，防止较早完成的调用清除新任务。
        let id: UUID
        /// 读取游标、网络拉取及事务应用的完整任务。
        let task: Task<V2GroupEventSyncProgress, any Error>
    }
    /// 按房间保存进行中的页面任务；同房间调用排队，不同房间可独立进行。
    private var pageFlights: [RoomID: PageFlight] = [:]

    /// Online bodies share the same room flight as durable pulls. Only a
    /// contiguous prefix advances the cursor; gaps remain recovery work.
    /// Returns false without waiting when the room already has a flight.
    /// The caller must retain the hint's target head for durable recovery.
    public func applyOnlineEvents(_ hint: V2GroupEventAvailabilityHint) async throws -> Bool {
        let roomID = hint.roomID
        try Task.checkCancellation()
        guard pageFlights[roomID] == nil else { return false }
        let current = PageFlight(id: UUID(), task: Task { [store] in
            let cursor = try await store.groupEventCursor(roomID: roomID)
            if hint.highWatermark <= cursor { return .init(appliedEventCount: 0, hasMore: false) }
            let candidates = hint.liveEvents.filter { $0.roomSequence > cursor }
            guard candidates.count <= V2GroupEventLogLimits.maximumPageSize,
                  candidates.allSatisfy({ $0.roomSequence <= hint.highWatermark && $0.roomSequence <= UInt64(Int64.max) }),
                  zip(candidates, candidates.dropFirst()).allSatisfy({ $1.roomSequence > $0.roomSequence }) else {
                return .init(appliedEventCount: 0, hasMore: true)
            }
            var through = cursor
            let events = candidates.prefix { event in
                guard through < UInt64(Int64.max), event.roomSequence == through + 1 else { return false }
                through = event.roomSequence
                return true
            }
            guard let last = events.last else { return .init(appliedEventCount: 0, hasMore: true) }
            try Task.checkCancellation()
            let page = try V2ClientGroupEventPage(roomID: roomID, events: Array(events),
                nextRoomSequence: last.roomSequence, hasMore: last.roomSequence < hint.highWatermark)
            let commit = try await store.applyGroupEventPageReportingChanges(page)
            return .init(appliedEventCount: commit.insertedEventCount, hasMore: commit.appliedThrough < hint.highWatermark)
        })
        pageFlights[roomID] = current
        defer { if pageFlights[roomID]?.id == current.id { pageFlights[roomID] = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await current.task.result
            try Task.checkCancellation()
            return try !result.get().hasMore
        }, onCancel: { current.task.cancel() })
    }
    /// 串行处理指定房间的一页可靠日志。
    ///
    /// - Parameter roomID: 要同步的房间。
    /// - Returns: 本事务新增事件数及服务端更多页面标志。
    /// - Throws: 取消、游标读取、响应校验、传输或应用错误。
    ///
    /// 若该房间已有任务，等待其结束后重新读游标并拉取自己的页面，不复用旧结果。
    /// 当前调用者取消会取消自己创建的任务；仅排队的调用者不会取消前一个任务。
    public func synchronizeOnePage(roomID: RoomID) async throws -> V2GroupEventSyncProgress {
        try await synchronizeOnePage(roomID: roomID) { [store] page in
            try await store.applyGroupEventPageReportingChanges(page)
        }
    }

    /// A recovery task supplies its atomic page-and-work commit while sharing
    /// the same per-room flight with foreground and ordinary page requests.
    public func synchronizeOnePage(
        roomID: RoomID,
        commit: @escaping @Sendable (V2ClientGroupEventPage) async throws -> V2GroupEventPageCommit
    ) async throws -> V2GroupEventSyncProgress {
        // Actor methods can interleave at network awaits. Serialize the entire
        // read/pull/apply sequence for this room, including foreground callers.
        while let previous = pageFlights[roomID] {
            _ = await previous.task.result
            try Task.checkCancellation()
            if pageFlights[roomID]?.id == previous.id { pageFlights[roomID] = nil }
        }
        try Task.checkCancellation()
        let current = PageFlight(id: UUID(), task: Task { [store, transport, pageSize] in
            let cursor = try await store.groupEventCursor(roomID: roomID)
            try Task.checkCancellation()
            let page = try await transport.pullGroupEvents(roomID: roomID, afterRoomSequence: cursor, pageSize: pageSize)
            try Task.checkCancellation()
            guard page.roomID == roomID,
                  page.nextRoomSequence >= cursor,
                  !page.hasMore || page.nextRoomSequence > cursor
            else { throw V2RealtimeTransportError.unexpectedResponse }
            let committed = try await commit(page)
            return .init(appliedEventCount: committed.insertedEventCount, hasMore: page.hasMore)
        })
        pageFlights[roomID] = current
        defer { if pageFlights[roomID]?.id == current.id { pageFlights[roomID] = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await current.task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { current.task.cancel() })
    }

    /// Reserve every room before awaiting cursors or the network. Foreground
    /// single-page reads and online delivery use the same flights, so batching
    /// cannot race their cursor reads or reorder page commits.
    func synchronizePages(targets: [(roomID: RoomID, head: UInt64)],
        commit: @escaping @Sendable ([V2ClientGroupEventPage]) async throws -> [RoomID: V2GroupEventPageCommit],
        unavailable: @escaping @Sendable (RoomID) async throws -> Void
    ) async throws -> V2GroupEventSyncProgress {
        guard (1...16).contains(targets.count), Set(targets.map(\.roomID)).count == targets.count else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        while let busy = targets.first(where: { pageFlights[$0.roomID] != nil }), let flight = pageFlights[busy.roomID] {
            _ = await flight.task.result
            try Task.checkCancellation()
            if pageFlights[busy.roomID]?.id == flight.id { pageFlights[busy.roomID] = nil }
        }
        try Task.checkCancellation()
        let current = PageFlight(id: UUID(), task: Task { [store, transport] in
            var requests: [V2ClientGroupEventPull] = []
            for target in targets {
                let cursor = try await store.groupEventCursor(roomID: target.roomID)
                try Task.checkCancellation()
                // A room watermark is only a scheduling hint. Request sizing
                // does not grant visibility or advance the durable cursor.
                let gap = target.head > cursor ? target.head - cursor : 1
                requests.append(.init(roomID: target.roomID, afterRoomSequence: cursor, pageSize: Int(min(UInt64(min(32, max(1, 64 / targets.count))), gap))))
            }
            let results = try await transport.pullGroupEventPages(requests)
            guard Set(results.keys) == Set(requests.map(\.roomID)) else { throw V2RealtimeTransportError.unexpectedResponse }
            var pages: [V2ClientGroupEventPage] = [], denied: [RoomID] = []
            var hasMore = false
            for request in requests {
                try Task.checkCancellation()
                switch results[request.roomID]! {
                case .page(let page):
                    guard page.roomID == request.roomID, page.events.count <= request.pageSize,
                          page.nextRoomSequence >= request.afterRoomSequence,
                          !page.hasMore || page.nextRoomSequence > request.afterRoomSequence
                    else { throw V2RealtimeTransportError.unexpectedResponse }
                    pages.append(page); hasMore = hasMore || page.hasMore
                case .failure(.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: _, currentRevision: _)):
                    denied.append(request.roomID)
                case .failure(let error): throw error
                }
            }
            for room in denied { try Task.checkCancellation(); try await unavailable(room) }
            try Task.checkCancellation()
            let committed = pages.isEmpty ? [:] : try await commit(pages)
            guard Set(committed.keys) == Set(pages.map(\.roomID)) else { throw V2RealtimeTransportError.unexpectedResponse }
            return .init(appliedEventCount: committed.values.reduce(0) { $0 + $1.insertedEventCount }, hasMore: hasMore)
        })
        for target in targets { pageFlights[target.roomID] = current }
        defer {
            for target in targets where pageFlights[target.roomID]?.id == current.id {
                pageFlights[target.roomID] = nil
            }
        }
        return try await withTaskCancellationHandler(operation: {
            let result = await current.task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { current.task.cancel() })
    }

    /// 逐页处理指定房间直到服务端不再声明更多事件；无固定页数上限，调用方持有取消与运行预算。
    public func synchronizeUntilCaughtUp(roomID: RoomID) async throws {
        while (try await synchronizeOnePage(roomID: roomID)).hasMore {
            try Task.checkCancellation()
        }
    }


}

/// 群事件分页的协议预算。
public enum V2GroupEventLogLimits {
    /// 每次群事件请求最多 500 条。
    public static let maximumPageSize = 500
}
