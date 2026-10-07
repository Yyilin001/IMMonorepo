import Foundation

public struct V2DirectRoomLogEventCacheSnapshot: Equatable, Sendable {
    public let cachedEvents: Int
    public let cachedRooms: Int
    public let cachedBytes: Int
    public let hits: UInt64
    public let misses: UInt64
    public let bypassedIneligibleEvents: UInt64
    public let pendingWrites: Int
    public let droppedWrites: UInt64

    public init(
        cachedEvents: Int,
        cachedRooms: Int,
        cachedBytes: Int,
        hits: UInt64,
        misses: UInt64,
        bypassedIneligibleEvents: UInt64,
        pendingWrites: Int = 0,
        droppedWrites: UInt64 = 0
    ) {
        self.cachedEvents = cachedEvents
        self.cachedRooms = cachedRooms
        self.cachedBytes = cachedBytes
        self.hits = hits
        self.misses = misses
        self.bypassedIneligibleEvents = bypassedIneligibleEvents
        self.pendingWrites = pendingWrites
        self.droppedWrites = droppedWrites
    }

    package static let empty = Self(
        cachedEvents: 0,
        cachedRooms: 0,
        cachedBytes: 0,
        hits: 0,
        misses: 0,
        bypassedIneligibleEvents: 0,
        pendingWrites: 0,
        droppedWrites: 0
    )

    package static func + (lhs: Self, rhs: Self) -> Self {
        .init(
            cachedEvents: lhs.cachedEvents + rhs.cachedEvents,
            cachedRooms: lhs.cachedRooms + rhs.cachedRooms,
            cachedBytes: lhs.cachedBytes + rhs.cachedBytes,
            hits: lhs.hits &+ rhs.hits,
            misses: lhs.misses &+ rhs.misses,
            bypassedIneligibleEvents:
                lhs.bypassedIneligibleEvents &+ rhs.bypassedIneligibleEvents,
            pendingWrites: lhs.pendingWrites + rhs.pendingWrites,
            droppedWrites: lhs.droppedWrites &+ rhs.droppedWrites
        )
    }
}

public struct V2PreparedGroupEventPageCacheSnapshot: Equatable, Sendable {
    /// 当前条目数。
    public let entries: Int
    /// 当前占用字节数。
    public let bytes: Int
    /// 命中次数。
    public let hits: UInt64
    /// 未命中次数。
    public let misses: UInt64
    /// 淘汰次数。
    public let evictions: UInt64

    package init(entries: Int, bytes: Int, hits: UInt64, misses: UInt64,
                 evictions: UInt64) {
        self.entries = entries
        self.bytes = bytes
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
    }
}

public struct V2DirectRoomLogFastAppendCacheSnapshot: Sendable, Equatable {
    public let entries: Int
    public let lookupHits: Int64
    public let lookupMisses: Int64
    public let attemptedAppends: Int64
    public let committedAppends: Int64
    public let fallbackAppends: Int64
    public let insertions: UInt64
    public let evictions: UInt64
    public let expirations: UInt64

    public init(
        entries: Int,
        lookupHits: Int64,
        lookupMisses: Int64,
        attemptedAppends: Int64,
        committedAppends: Int64,
        fallbackAppends: Int64,
        insertions: UInt64 = 0,
        evictions: UInt64 = 0,
        expirations: UInt64 = 0
    ) {
        self.entries = entries
        self.lookupHits = lookupHits
        self.lookupMisses = lookupMisses
        self.attemptedAppends = attemptedAppends
        self.committedAppends = committedAppends
        self.fallbackAppends = fallbackAppends
        self.insertions = insertions
        self.evictions = evictions
        self.expirations = expirations
    }
}

public struct V2DirectSendPolicyCacheSnapshot: Equatable, Sendable {
    /// 当前条目数。
    public let entries: Int
    /// 命中次数。
    public let hits: UInt64
    /// 未命中次数。
    public let misses: UInt64
    /// 写入次数。
    public let insertions: UInt64
    /// 因容量淘汰的次数。
    public let evictions: UInt64
    /// 因过期移除的次数。
    public let expirations: UInt64

    package init(entries: Int, hits: UInt64, misses: UInt64,
                 insertions: UInt64, evictions: UInt64, expirations: UInt64) {
        self.entries = entries
        self.hits = hits
        self.misses = misses
        self.insertions = insertions
        self.evictions = evictions
        self.expirations = expirations
    }
}

public struct V2LivePresenceRenewalBatcherSnapshot: Equatable, Sendable {
    /// 当前待刷新连接数。
    public let pendingConnections: Int
    /// 累计提交的续租请求数。
    public let submittedRequests: UInt64
    /// 已执行的批次数。
    public let executedBatches: UInt64
    /// 失败的批次数。
    public let failedBatches: UInt64
    /// 历史最大批次规模。
    public let largestBatch: Int

    /// 保存快照。
    ///
    /// - Parameters:
    ///   - pendingConnections: 待刷新连接数。
    ///   - submittedRequests: 累计请求数。
    ///   - executedBatches: 已执行批次数。
    ///   - failedBatches: 失败批次数。
    ///   - largestBatch: 历史最大批次规模。
    public init(
        pendingConnections: Int,
        submittedRequests: UInt64,
        executedBatches: UInt64,
        failedBatches: UInt64,
        largestBatch: Int
    ) {
        self.pendingConnections = pendingConnections
        self.submittedRequests = submittedRequests
        self.executedBatches = executedBatches
        self.failedBatches = failedBatches
        self.largestBatch = largestBatch
    }
}
