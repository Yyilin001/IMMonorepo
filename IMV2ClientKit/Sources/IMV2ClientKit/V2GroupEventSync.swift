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

/// 按页面预算执行的后台房间扫描结果，避免一个大历史房间耗尽整个重连周期。
public struct V2GroupEventBackgroundSyncProgress: Equatable, Sendable {
    /// 本轮消耗的房间处理预算，已跳过或被拒绝的房间也可能计入。
    public let processedPageCount: Int
    /// 本轮可靠页面事务新增事件总数。
    public let appliedEventCount: Int
    /// 当前有限目录扫描或已知页面积压是否尚未结束；为 false 后可由下次唤醒开始新扫描。
    public let mayHaveRemainingWork: Bool

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - processedPageCount: 本轮消耗的房间处理预算，已跳过或被拒绝的房间也可能计入。
    ///   - appliedEventCount: 本轮可靠页面事务新增事件总数。
    ///   - mayHaveRemainingWork: 当前有限目录扫描或已知页面积压是否尚未结束；为 false 后可由下次唤醒开始新扫描。
    ///
    /// 初始化仅保存字段，不执行额外范围或状态一致性校验。
    public init(processedPageCount: Int, appliedEventCount: Int, mayHaveRemainingWork: Bool) {
        self.processedPageCount = processedPageCount
        self.appliedEventCount = appliedEventCount
        self.mayHaveRemainingWork = mayHaveRemainingWork
    }
}

/// 读取获授权房间日志页面的网络边界，不负责本地投影提交。
public protocol V2ClientGroupEventTransport: Sendable {
    /// 从给定房间水位之后拉取一页事件，调用者提供页大小预算；失败抛出传输或服务端错误。
    func pullGroupEvents(roomID: RoomID, afterRoomSequence: UInt64, pageSize: Int) async throws -> V2ClientGroupEventPage
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

/// 房间事件读取用途，区分可靠恢复日志与普通用户同步之上的前台预览。
public enum V2ClientRoomEventDelivery: Equatable, Sendable {
    /// 房间日志是该房间的持久化恢复来源。
    case durableRoomLog
    /// 仅供前台加速预览，可靠恢复与确认仍依赖用户同步。
    case foregroundPreview
}

/// 本地房间投递方式及当前访问状态；私聊明确使用可靠房间日志，标准群使用前台预览。
public struct V2ClientGroupEventAccess: Equatable, Sendable {
    /// 房间固定的日志投递方式。
    public let delivery: V2ClientRoomEventDelivery
    /// 当前本地状态是否允许读取。
    public let isAuthorized: Bool

    /// 创建对应的房间事件状态值。
    ///
    /// - Parameters:
    ///   - delivery: 房间固定的日志投递方式。
    ///   - isAuthorized: 当前本地状态是否允许读取。
    ///
    /// 初始化仅保存字段，不执行额外范围或状态一致性校验。
    public init(delivery: V2ClientRoomEventDelivery, isAuthorized: Bool) {
        self.delivery = delivery
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

/// 可靠房间日志的本地事务和后台目录边界。
///
/// 适用于 Hybrid 大群和私聊，标准扇出群不进入此后台目录。每页投影与房间游标必须在同一事务提交。
public protocol V2LocalGroupEventStore: Sendable {
    /// 按房间身份 keyset 顺序读取指定位置之后的有界可靠日志目录，包含 Hybrid 大群与私聊，不包含标准扇出群。
    func knownRoomLogRoomIDs(after roomID: RoomID?, limit: Int) async throws -> [RoomID]
    /// 读取当前可靠日志目录最大房间身份，作为一次有限扫描的包含式上界；空目录返回 nil。
    func lastKnownRoomLogRoomID() async throws -> RoomID?
    /// 读取持久化轮转位置，仅作为公平调度提示；实际投递水位仍以每房间游标为准。
    func hybridGroupBackgroundCursor() async throws -> RoomID?
    /// 保存轮转调度位置；nil 表示清除位置，不改变任何房间的已应用事件水位。
    func setHybridGroupBackgroundCursor(_ roomID: RoomID?) async throws
    /// 检查房间当前是否仍属于可处理的可靠日志目录，供调度前复核。
    func isKnownRoomLogRoom(roomID: RoomID) async throws -> Bool
    /// 服务端明确拒绝访问后标记房间无读取权限，停止后续补拉；保留历史本地投影与固定投递方式。
    func markRoomEventUnauthorized(roomID: RoomID) async throws
    /// 读取该房间已持久化的事件水位，供下次拉取使用；读取或状态错误通过抛出报告。
    func groupEventCursor(roomID: RoomID) async throws -> UInt64
    /// 验证并原子应用事件页及其房间游标，返回提交水位；失败不能只推进游标而遗漏投影。
    func applyGroupEventPage(_ page: V2ClientGroupEventPage) async throws -> UInt64
    /// 原子提交事件页与游标，并报告本事务新增条数，排除精确重放；失败通过存储或校验错误报告。
    func applyGroupEventPageReportingChanges(_ page: V2ClientGroupEventPage) async throws -> V2GroupEventPageCommit
}

/// 标准扇出群的前台预览存储合同。
///
/// 预览游标只在进程内保存，不能作为持久化同步确认；用户同步日志仍负责恢复与确认。
public protocol V2LocalForegroundGroupEventPreviewStore: Sendable {
    /// 读取固定投递方式与当前本地访问状态；未知房间返回 nil。
    func groupEventAccess(roomID: RoomID) async throws -> V2ClientGroupEventAccess?
    /// 读取内存预览游标的安全下界，允许重启后重复拉取，但不能跳过应读取事件。
    func foregroundGroupEventPreviewStartSequence(roomID: RoomID) async throws -> UInt64
    /// 幂等应用临时预览页面，不写入可靠群事件游标，也不能作为用户同步确认。
    func applyForegroundGroupEventPreviewPage(_ page: V2ClientGroupEventPage) async throws -> UInt64
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
    /// 当前后台扫描任务及其身份，避免多个后台预算周期同时修改扫描状态。
    private var backgroundFlight: (id: UUID, task: Task<V2GroupEventBackgroundSyncProgress, any Error>)?

    /// 一次有限 keyset 扫描区间，起点不含、终点包含。
    private struct DirectoryRange {
        /// 本区间已处理的排除式起点，nil 表示从目录头开始。
        var after: RoomID?
        /// 建立本轮扫描时捕获的包含式终点。
        let through: RoomID
    }
    /// 跨后台预算调用保留的内存扫描进度；进程重启依赖持久化轮转位置重新建立扫描。
    private struct Scan {
        /// 尚未扫描的有界目录区间，按轮转顺序处理。
        var ranges: [DirectoryRange]
        /// 当前目录页中尚未处理的房间。
        var pendingRooms: [RoomID] = []
        /// 已明确返回 hasMore 的房间队列，目录扫描后继续轮转。
        var backlog: [RoomID] = []
        /// 积压队列首个未消费位置，避免每次处理都移动整个数组。
        var backlogHead = 0
        /// 目录区间、当前目录页或未消费积压队列任一非空时为真。
        var hasWork: Bool { !ranges.isEmpty || !pendingRooms.isEmpty || backlogHead < backlog.count }
    }
    /// 当前未完成的有限扫描，没有剩余工作时清空，下一次唤醒重新捕获目录上界。
    private var scan: Scan?

    /// 串行处理指定房间的一页可靠日志。
    ///
    /// - Parameter roomID: 要同步的房间。
    /// - Returns: 本事务新增事件数及服务端更多页面标志。
    /// - Throws: 取消、游标读取、响应校验、传输或应用错误。
    ///
    /// 若该房间已有任务，等待其结束后重新读游标并拉取自己的页面，不复用旧结果。
    /// 当前调用者取消会取消自己创建的任务；仅排队的调用者不会取消前一个任务。
    public func synchronizeOnePage(roomID: RoomID) async throws -> V2GroupEventSyncProgress {
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
            let commit = try await store.applyGroupEventPageReportingChanges(page)
            return .init(appliedEventCount: commit.insertedEventCount, hasMore: page.hasMore)
        })
        pageFlights[roomID] = current
        defer { if pageFlights[roomID]?.id == current.id { pageFlights[roomID] = nil } }
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

    /// 从持久化轮转位置继续一次有限目录扫描和已知页面积压。
    ///
    /// - Parameter maximumPages: 本轮页面预算，范围 1 到 10000，越界触发前置条件失败。
    /// - Returns: 已消耗预算、实际新增事件数及是否仍有本轮工作。
    /// - Throws: 取消、目录、传输或存储错误。
    ///
    /// 并发后台调用排队执行，各自运行新一轮预算。捕获扫描上界之后新增的房间留待以后扫描；
    /// 只有返回 hasMore 的房间进入后续队列，空房间不会因目录超过预算而永远循环。
    public func synchronizeBackgroundKnownRooms(maximumPages: Int) async throws -> V2GroupEventBackgroundSyncProgress {
        precondition(maximumPages > 0 && maximumPages <= 10_000)
        while let previous = backgroundFlight {
            _ = await previous.task.result
            try Task.checkCancellation()
            if backgroundFlight?.id == previous.id { backgroundFlight = nil }
        }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await self.synchronizeBackgroundPass(maximumPages: maximumPages) }
        backgroundFlight = (id, task)
        defer { if backgroundFlight?.id == id { backgroundFlight = nil } }
        return try await withTaskCancellationHandler(operation: {
            let result = await task.result
            try Task.checkCancellation()
            return try result.get()
        }, onCancel: { task.cancel() })
    }

    /// 执行一轮公平页面预算，保存可跨调用继续的内存扫描状态。
    ///
    /// 首次以持久化位置为分割点建立有限的尾段和头段目录；每轮每个房间最多处理一页，目录优先于已知积压。
    /// FORBIDDEN 被转换为本地无权限标记，其他错误传播。处理后保存轮转位置，目录中已失效房间也会消耗一次预算。
    /// 即使异常退出也保留尚有工作的扫描状态；每房间持久化游标仍负责崩溃恢复。
    private func synchronizeBackgroundPass(maximumPages: Int) async throws -> V2GroupEventBackgroundSyncProgress {
        if scan == nil {
            let pivot = try await store.hybridGroupBackgroundCursor()
            guard let upper = try await store.lastKnownRoomLogRoomID() else {
                try await store.setHybridGroupBackgroundCursor(nil)
                return .init(processedPageCount: 0, appliedEventCount: 0, mayHaveRemainingWork: false)
            }
            var ranges: [DirectoryRange] = []
            if let pivot {
                if pivot.rawValue < upper.rawValue { ranges.append(.init(after: pivot, through: upper)) }
            } else {
                ranges.append(.init(after: nil, through: upper))
            }
            if let pivot {
                ranges.append(.init(after: nil, through: pivot.rawValue < upper.rawValue ? pivot : upper))
            }
            scan = .init(ranges: ranges)
        }
        guard var scan else { throw V2RealtimeTransportError.unexpectedResponse }
        defer { self.scan = scan.hasWork ? scan : nil }
        var processedPages = 0
        var appliedEvents = 0
        var visited = Set<RoomID>()
        while processedPages < maximumPages {
            try Task.checkCancellation()
            // Keep only a bounded keyset page in memory. Each range advances
            // once; the head range ends at the original persisted pivot.
            while scan.pendingRooms.isEmpty, let range = scan.ranges.first {
                let rows = try await store.knownRoomLogRoomIDs(after: range.after, limit: maximumPages)
                try Task.checkCancellation()
                let bounded = rows.prefix { $0.rawValue <= range.through.rawValue }
                scan.pendingRooms = Array(bounded)
                if rows.count < maximumPages || bounded.count < rows.count || bounded.last == range.through {
                    scan.ranges.removeFirst()
                } else if let last = bounded.last {
                    scan.ranges[0].after = last
                }
            }
            let isDirectory = !scan.pendingRooms.isEmpty
            let roomID: RoomID
            if let first = scan.pendingRooms.first {
                roomID = first
            } else if scan.backlogHead < scan.backlog.count {
                roomID = scan.backlog[scan.backlogHead]
            } else { break }
            // One page per room per quantum, even at the directory/backlog boundary.
            guard visited.insert(roomID).inserted else { break }
            var hasMore = false
            do {
                if try await store.isKnownRoomLogRoom(roomID: roomID) {
                    let progress = try await synchronizeOnePage(roomID: roomID)
                    appliedEvents += progress.appliedEventCount
                    hasMore = progress.hasMore
                }
            } catch let error as V2RealtimeTransportError {
                guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
                try await store.markRoomEventUnauthorized(roomID: roomID)
            }
            try Task.checkCancellation()
            try await store.setHybridGroupBackgroundCursor(roomID)
            processedPages += 1
            if isDirectory { scan.pendingRooms.removeFirst() }
            else { scan.backlogHead += 1 }
            if hasMore { scan.backlog.append(roomID) }
        }
        let remaining = scan.hasWork
        if scan.backlogHead > 64 {
            scan.backlog.removeFirst(scan.backlogHead)
            scan.backlogHead = 0
        }
        return .init(processedPageCount: processedPages, appliedEventCount: appliedEvents, mayHaveRemainingWork: remaining)
    }

}

/// 标准扇出群的前台尽力预览引擎。
///
/// 游标仅保存在内存，重建引擎后从存储提供的安全下界开始，可能重复应用。可靠恢复依赖用户同步。
/// 此 actor 没有可靠引擎的每房间任务串行门；调用方应避免重叠刷新，存储应用仍需幂等。
public actor V2ForegroundGroupEventPreviewEngine {
    /// 读取群事件页的传输依赖。
    private let transport: any V2ClientGroupEventTransport
    /// 按本引擎可靠或预览合同应用事件的存储依赖。
    private let store: any V2LocalForegroundGroupEventPreviewStore
    /// 每次网络拉取的页面预算。
    private let pageSize: Int
    /// 仅在进程内保存的各房间预览水位，不作为可靠确认。
    private var cursors: [RoomID: UInt64] = [:]

    /// 配置事件读取与本地应用依赖，不在初始化时启动同步。
    ///
    /// - Parameters:
    ///   - transport: 群事件传输。
    ///   - store: 对应的本地存储实现。
    ///   - pageSize: 单页预算，默认 200，必须大于零且不超过 500。
    ///
    /// 页大小无效时触发前置条件失败。
    public init(
        transport: any V2ClientGroupEventTransport,
        store: any V2LocalForegroundGroupEventPreviewStore,
        pageSize: Int = 200
    ) {
        precondition(pageSize > 0 && pageSize <= V2GroupEventLogLimits.maximumPageSize)
        self.transport = transport
        self.store = store
        self.pageSize = pageSize
    }

    /// 读取缓存的预览水位，首次从存储安全下界初始化；并发调用跨 await 可能交错，调用方需协调刷新。
    public func cursor(roomID: RoomID) async throws -> UInt64 {
        if let cursor = cursors[roomID] { return cursor }
        let cursor = try await store.foregroundGroupEventPreviewStartSequence(roomID: roomID)
        cursors[roomID] = cursor
        return cursor
    }

    /// 读取并幂等应用一页前台预览，成功后推进内存水位。
    ///
    /// - Parameter roomID: 要预览的房间。
    /// - Returns: 页面事件条数与更多页面标志，条数不排除重复投影。
    /// - Throws: 游标、传输、响应顺序或应用错误。
    ///
    /// 检查房间、后续水位和事件严格顺序，不写可靠日志确认。没有跨整个请求的每房间串行门，
    /// 也没有在每个阶段主动检查取消；上层需管理重叠刷新与生命周期。
    public func synchronizeOnePage(roomID: RoomID) async throws -> V2GroupEventSyncProgress {
        let cursor = try await cursor(roomID: roomID)
        let page = try await transport.pullGroupEvents(roomID: roomID, afterRoomSequence: cursor, pageSize: pageSize)
        guard page.roomID == roomID,
              page.nextRoomSequence >= cursor,
              (page.events.last?.roomSequence ?? cursor) <= page.nextRoomSequence,
              !page.hasMore || page.nextRoomSequence > cursor,
              zip(page.events, page.events.dropFirst()).allSatisfy({ $0.roomSequence < $1.roomSequence })
        else { throw V2RealtimeTransportError.unexpectedResponse }
        _ = try await store.applyForegroundGroupEventPreviewPage(page)
        cursors[roomID] = page.nextRoomSequence
        return .init(appliedEventCount: page.events.count, hasMore: page.hasMore)
    }

    /// 移除房间内存游标，下一次从存储安全下界开始；不取消已经进行的拉取，正在完成的操作仍可能重新写回游标。
    public func forget(roomID: RoomID) {
        cursors.removeValue(forKey: roomID)
    }
}

/// 群事件分页的协议预算。
public enum V2GroupEventLogLimits {
    /// 每次群事件请求最多 500 条。
    public static let maximumPageSize = 500
}
