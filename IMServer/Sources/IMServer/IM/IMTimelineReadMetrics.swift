import Vapor

enum IMTimelineSinceCacheInvalidationMode: String, Sendable {
    case disabled
    case redis
}

struct IMTimelineSinceCacheInvalidationConfiguration: Sendable {
    let mode: IMTimelineSinceCacheInvalidationMode
    let redisURL: String?
    let maximumConnectionCount: Int

    static func load(from environment: Environment) -> IMTimelineSinceCacheInvalidationConfiguration {
        let configuredMode = Environment.get("IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE")
            .flatMap(IMTimelineSinceCacheInvalidationMode.init(rawValue:))
        let redisURL = Environment.get("IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_URL")?.nilIfBlank
            ?? Environment.get("REDIS_URL")?.nilIfBlank
        return IMTimelineSinceCacheInvalidationConfiguration(
            mode: configuredMode ?? (redisURL == nil ? .disabled : .redis),
            redisURL: redisURL,
            maximumConnectionCount: max(
                2,
                Environment.get("IM_TIMELINE_SINCE_CACHE_INVALIDATION_REDIS_MAX_CONNECTIONS")
                    .flatMap(Int.init(_:)) ?? 2
            )
        )
    }
}

struct IMTimelineReadConfiguration: Sendable {
    static let defaultVisibilityScanMaxRows = 5_000
    static let defaultVisibilityScanMaxPages = 50
    static let defaultSinceHotCacheTTLMilliseconds = 250
    static let defaultSinceHotCacheMaxEntries = 4_096
    static let defaultSinceRecentCacheTTLMilliseconds = 2_000
    static let defaultSinceRecentCacheMaxConversations = 1_024
    static let defaultSinceRecentCacheMaxItemsPerConversation = 512
    static let defaultSinceTargetSequenceCoalesceWindowMilliseconds = 5

    let visibilityScanMaxRows: Int
    let visibilityScanMaxPages: Int
    let sinceHotCacheTTLMilliseconds: Int
    let sinceHotCacheMaxEntries: Int
    let sinceRecentCacheTTLMilliseconds: Int
    let sinceRecentCacheMaxConversations: Int
    let sinceRecentCacheMaxItemsPerConversation: Int
    let sinceTargetSequenceCoalesceWindowMilliseconds: Int

    init(
        visibilityScanMaxRows: Int = IMTimelineReadConfiguration.defaultVisibilityScanMaxRows,
        visibilityScanMaxPages: Int = IMTimelineReadConfiguration.defaultVisibilityScanMaxPages,
        sinceHotCacheTTLMilliseconds: Int = IMTimelineReadConfiguration.defaultSinceHotCacheTTLMilliseconds,
        sinceHotCacheMaxEntries: Int = IMTimelineReadConfiguration.defaultSinceHotCacheMaxEntries,
        sinceRecentCacheTTLMilliseconds: Int = IMTimelineReadConfiguration.defaultSinceRecentCacheTTLMilliseconds,
        sinceRecentCacheMaxConversations: Int = IMTimelineReadConfiguration.defaultSinceRecentCacheMaxConversations,
        sinceRecentCacheMaxItemsPerConversation: Int = IMTimelineReadConfiguration.defaultSinceRecentCacheMaxItemsPerConversation,
        sinceTargetSequenceCoalesceWindowMilliseconds: Int = IMTimelineReadConfiguration.defaultSinceTargetSequenceCoalesceWindowMilliseconds
    ) {
        self.visibilityScanMaxRows = max(1, visibilityScanMaxRows)
        self.visibilityScanMaxPages = max(1, visibilityScanMaxPages)
        self.sinceHotCacheTTLMilliseconds = max(0, sinceHotCacheTTLMilliseconds)
        self.sinceHotCacheMaxEntries = max(0, sinceHotCacheMaxEntries)
        self.sinceRecentCacheTTLMilliseconds = max(0, sinceRecentCacheTTLMilliseconds)
        self.sinceRecentCacheMaxConversations = max(0, sinceRecentCacheMaxConversations)
        self.sinceRecentCacheMaxItemsPerConversation = max(0, sinceRecentCacheMaxItemsPerConversation)
        self.sinceTargetSequenceCoalesceWindowMilliseconds = max(0, sinceTargetSequenceCoalesceWindowMilliseconds)
    }

    var isSinceHotCacheEnabled: Bool {
        sinceHotCacheTTLMilliseconds > 0 && sinceHotCacheMaxEntries > 0
    }

    var isSinceRecentCacheEnabled: Bool {
        sinceRecentCacheTTLMilliseconds > 0 &&
            sinceRecentCacheMaxConversations > 0 &&
            sinceRecentCacheMaxItemsPerConversation > 0
    }

    var requiresSinceCacheInvalidation: Bool {
        isSinceHotCacheEnabled || isSinceRecentCacheEnabled
    }

    static func load(from environment: Environment) -> IMTimelineReadConfiguration {
        IMTimelineReadConfiguration(
            visibilityScanMaxRows: Environment.get("IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS")
                .flatMap(Int.init(_:)) ?? defaultVisibilityScanMaxRows,
            visibilityScanMaxPages: Environment.get("IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_PAGES")
                .flatMap(Int.init(_:)) ?? defaultVisibilityScanMaxPages,
            sinceHotCacheTTLMilliseconds: Environment.get("IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS")
                .flatMap(Int.init(_:)) ?? defaultSinceHotCacheTTLMilliseconds,
            sinceHotCacheMaxEntries: Environment.get("IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES")
                .flatMap(Int.init(_:)) ?? defaultSinceHotCacheMaxEntries,
            sinceRecentCacheTTLMilliseconds: Environment.get("IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS")
                .flatMap(Int.init(_:)) ?? defaultSinceRecentCacheTTLMilliseconds,
            sinceRecentCacheMaxConversations: Environment.get("IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS")
                .flatMap(Int.init(_:)) ?? defaultSinceRecentCacheMaxConversations,
            sinceRecentCacheMaxItemsPerConversation: Environment.get("IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION")
                .flatMap(Int.init(_:)) ?? defaultSinceRecentCacheMaxItemsPerConversation,
            sinceTargetSequenceCoalesceWindowMilliseconds: Environment.get("IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS")
                .flatMap(Int.init(_:)) ?? defaultSinceTargetSequenceCoalesceWindowMilliseconds
        )
    }
}

final class IMTimelineSinceRecentCache: @unchecked Sendable {
    struct Key: Hashable {
        let conversationID: UUID
        let minimumVisibleServerSequence: Int
    }

    private struct Entry {
        let sourceLowerTimelineBound: Int
        let items: [IMTimelineItemResponse]
        let hasMore: Bool
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entriesByKey: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []

    func response(
        conversationID: UUID,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        limit: Int,
        now: Date = Date()
    ) -> IMTimelinePageResponse? {
        let key = Key(
            conversationID: conversationID,
            minimumVisibleServerSequence: minimumVisibleServerSequence
        )
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entriesByKey[key] else {
            return nil
        }
        guard entry.expiresAt > now else {
            entriesByKey.removeValue(forKey: key)
            insertionOrder.removeAll { $0 == key }
            return nil
        }
        guard lowerTimelineBound >= entry.sourceLowerTimelineBound else {
            return nil
        }

        let itemsAfterLowerBound = entry.items.filter {
            $0.timelineSequence > UInt64(lowerTimelineBound)
        }
        guard itemsAfterLowerBound.count >= limit || !entry.hasMore else {
            return nil
        }
        let pageItems = Array(itemsAfterLowerBound.prefix(limit))
        let hasMore = itemsAfterLowerBound.count > limit || entry.hasMore
        return IMTimelinePageResponse(
            items: pageItems,
            hasMore: hasMore,
            nextAfterSequence: pageItems.last?.timelineSequence ?? UInt64(lowerTimelineBound)
        )
    }

    @discardableResult
    func store(
        _ response: IMTimelinePageResponse,
        conversationID: UUID,
        minimumVisibleServerSequence: Int,
        lowerTimelineBound: Int,
        ttlMilliseconds: Int,
        maxConversations: Int,
        maxItemsPerConversation: Int,
        now: Date = Date()
    ) -> Bool {
        guard ttlMilliseconds > 0,
              maxConversations > 0,
              maxItemsPerConversation > 0,
              !response.items.isEmpty,
              response.items.allSatisfy({ $0.notice == nil })
        else {
            return false
        }

        let key = Key(
            conversationID: conversationID,
            minimumVisibleServerSequence: minimumVisibleServerSequence
        )
        let clippedItems = Array(response.items.suffix(maxItemsPerConversation))
        let effectiveSourceLowerTimelineBound: Int
        if clippedItems.count == response.items.count {
            effectiveSourceLowerTimelineBound = lowerTimelineBound
        } else if let firstCachedTimelineSequence = clippedItems.first?.timelineSequence,
                  firstCachedTimelineSequence <= UInt64(Int.max) {
            effectiveSourceLowerTimelineBound = max(
                lowerTimelineBound,
                Int(firstCachedTimelineSequence) - 1
            )
        } else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        if entriesByKey[key] == nil {
            insertionOrder.append(key)
        }
        entriesByKey[key] = Entry(
            sourceLowerTimelineBound: effectiveSourceLowerTimelineBound,
            items: clippedItems,
            hasMore: response.hasMore,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlMilliseconds) / 1_000)
        )
        evictOverflow(maxConversations: maxConversations)
        return true
    }

    @discardableResult
    func invalidate(conversationID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let removedCount = entriesByKey.keys.filter { $0.conversationID == conversationID }.count
        guard removedCount > 0 else {
            return 0
        }
        entriesByKey = entriesByKey.filter { $0.key.conversationID != conversationID }
        insertionOrder.removeAll { $0.conversationID == conversationID }
        return removedCount
    }

    private func evictOverflow(maxConversations: Int) {
        while insertionOrder.count > maxConversations {
            let key = insertionOrder.removeFirst()
            entriesByKey.removeValue(forKey: key)
        }
    }
}

final class IMTimelineSinceHotCache: @unchecked Sendable {
    struct Key: Hashable {
        let conversationID: UUID
        let lowerTimelineBound: Int
        let minimumVisibleServerSequence: Int
        let limit: Int
    }

    private struct Entry {
        let response: IMTimelinePageResponse
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entriesByKey: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []

    func response(for key: Key, now: Date = Date()) -> IMTimelinePageResponse? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entriesByKey[key] else {
            return nil
        }
        guard entry.expiresAt > now else {
            entriesByKey.removeValue(forKey: key)
            insertionOrder.removeAll { $0 == key }
            return nil
        }
        return entry.response
    }

    func store(
        _ response: IMTimelinePageResponse,
        for key: Key,
        ttlMilliseconds: Int,
        maxEntries: Int,
        now: Date = Date()
    ) {
        guard ttlMilliseconds > 0, maxEntries > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if entriesByKey[key] == nil {
            insertionOrder.append(key)
        }
        entriesByKey[key] = Entry(
            response: response,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlMilliseconds) / 1_000)
        )
        evictOverflow(maxEntries: maxEntries)
    }

    @discardableResult
    func invalidate(conversationID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let removedCount = entriesByKey.keys.filter { $0.conversationID == conversationID }.count
        guard removedCount > 0 else {
            return 0
        }
        entriesByKey = entriesByKey.filter { $0.key.conversationID != conversationID }
        insertionOrder.removeAll { $0.conversationID == conversationID }
        return removedCount
    }

    private func evictOverflow(maxEntries: Int) {
        while insertionOrder.count > maxEntries {
            let key = insertionOrder.removeFirst()
            entriesByKey.removeValue(forKey: key)
        }
    }
}

actor IMTimelineSinceVisibilitySafetyCache {
    struct Key: Hashable, Sendable {
        let conversationID: UUID
        let lowerTimelineBound: Int
    }

    private struct Entry: Sendable {
        let hasHiddenOverrides: Bool
        let expiresAt: Date
    }

    private var entriesByKey: [Key: Entry] = [:]
    private var inFlightByKey: [Key: Task<Bool, any Error>] = [:]

    func hasHiddenOverrides(
        for key: Key,
        ttlMilliseconds: Int,
        loader: @escaping @Sendable () async throws -> Bool
    ) async throws -> (hasHiddenOverrides: Bool, cacheHit: Bool, joinedInFlight: Bool) {
        if ttlMilliseconds > 0,
           let entry = entriesByKey[key] {
            if entry.expiresAt > Date() {
                return (entry.hasHiddenOverrides, true, false)
            }
            entriesByKey.removeValue(forKey: key)
        }

        if let inFlight = inFlightByKey[key] {
            return (try await inFlight.value, false, true)
        }

        let task = Task {
            try await loader()
        }
        inFlightByKey[key] = task
        do {
            let hasHiddenOverrides = try await task.value
            inFlightByKey.removeValue(forKey: key)
            if ttlMilliseconds > 0, hasHiddenOverrides {
                entriesByKey[key] = Entry(
                    hasHiddenOverrides: hasHiddenOverrides,
                    expiresAt: Date().addingTimeInterval(TimeInterval(ttlMilliseconds) / 1_000)
                )
            }
            return (hasHiddenOverrides, false, false)
        } catch {
            inFlightByKey.removeValue(forKey: key)
            throw error
        }
    }

    @discardableResult
    func invalidate(conversationID: UUID) -> Int {
        let removedEntries = entriesByKey.keys.filter { $0.conversationID == conversationID }.count
        guard removedEntries > 0 else {
            return 0
        }
        entriesByKey = entriesByKey.filter { $0.key.conversationID != conversationID }
        inFlightByKey = inFlightByKey.filter { $0.key.conversationID != conversationID }
        return removedEntries
    }
}

actor IMTimelineSinceResponseCoalescer {
    struct Key: Hashable, Sendable {
        let hotCacheKey: IMTimelineSinceHotCache.Key
        let targetSequence: Int?
    }

    struct TargetSequenceKey: Hashable, Sendable {
        let conversationID: UUID
        let minimumVisibleServerSequence: Int
        let targetSequence: Int
    }

    struct PageResult: Sendable {
        let response: IMTimelinePageResponse
        let scannedRows: Int
        let scannedPages: Int
    }

    struct TargetSequenceRequestResult: Sendable {
        let result: PageResult
        let joinedWindow: Bool
        let coalescedRequestCount: Int
    }

    typealias TargetSequenceLoader = @Sendable (_ lowerTimelineBound: Int, _ limit: Int) async throws -> PageResult

    private struct TargetSequenceRequest {
        let lowerTimelineBound: Int
        let limit: Int
        let continuation: CheckedContinuation<TargetSequenceRequestResult, any Error>
    }

    private struct TargetSequenceBatch {
        var requests: [TargetSequenceRequest]
        let loader: TargetSequenceLoader
    }

    private var inFlightByKey: [Key: Task<PageResult, any Error>] = [:]
    private var targetSequenceBatchesByKey: [TargetSequenceKey: TargetSequenceBatch] = [:]

    func response(
        for key: IMTimelineSinceHotCache.Key,
        targetSequence: Int? = nil,
        loader: @escaping @Sendable () async throws -> PageResult
    ) async throws -> (result: PageResult, joinedInFlight: Bool) {
        let coalescingKey = Key(hotCacheKey: key, targetSequence: targetSequence)
        if let inFlight = inFlightByKey[coalescingKey] {
            return (try await inFlight.value, true)
        }

        let task = Task {
            try await loader()
        }
        inFlightByKey[coalescingKey] = task
        do {
            let response = try await task.value
            inFlightByKey.removeValue(forKey: coalescingKey)
            return (response, false)
        } catch {
            inFlightByKey.removeValue(forKey: coalescingKey)
            throw error
        }
    }

    func targetSequenceResponse(
        for key: IMTimelineSinceHotCache.Key,
        targetSequence: Int,
        coalescingWindowMilliseconds: Int,
        loader: @escaping TargetSequenceLoader
    ) async throws -> TargetSequenceRequestResult {
        guard coalescingWindowMilliseconds > 0 else {
            let result = try await loader(key.lowerTimelineBound, key.limit)
            return TargetSequenceRequestResult(
                result: result,
                joinedWindow: false,
                coalescedRequestCount: 1
            )
        }

        let targetKey = TargetSequenceKey(
            conversationID: key.conversationID,
            minimumVisibleServerSequence: key.minimumVisibleServerSequence,
            targetSequence: targetSequence
        )
        return try await withCheckedThrowingContinuation { continuation in
            let request = TargetSequenceRequest(
                lowerTimelineBound: key.lowerTimelineBound,
                limit: key.limit,
                continuation: continuation
            )
            if var batch = targetSequenceBatchesByKey[targetKey] {
                batch.requests.append(request)
                targetSequenceBatchesByKey[targetKey] = batch
                return
            }

            targetSequenceBatchesByKey[targetKey] = TargetSequenceBatch(
                requests: [request],
                loader: loader
            )
            Task {
                try? await Task.sleep(nanoseconds: UInt64(coalescingWindowMilliseconds) * 1_000_000)
                await self.flushTargetSequenceBatch(for: targetKey)
            }
        }
    }

    func cancel(conversationID: UUID) {
        let matchingKeys = inFlightByKey.keys.filter { $0.hotCacheKey.conversationID == conversationID }
        for key in matchingKeys {
            inFlightByKey[key]?.cancel()
            inFlightByKey.removeValue(forKey: key)
        }
        let targetKeys = targetSequenceBatchesByKey.keys.filter { $0.conversationID == conversationID }
        for key in targetKeys {
            guard let batch = targetSequenceBatchesByKey.removeValue(forKey: key) else {
                continue
            }
            for request in batch.requests {
                request.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func flushTargetSequenceBatch(for key: TargetSequenceKey) async {
        guard let batch = targetSequenceBatchesByKey.removeValue(forKey: key) else {
            return
        }
        guard !batch.requests.isEmpty else {
            return
        }
        let lowerTimelineBound = batch.requests.map(\.lowerTimelineBound).min() ?? 0
        let limit = batch.requests.map(\.limit).max() ?? 1
        do {
            let result = try await batch.loader(lowerTimelineBound, limit)
            let requestCount = batch.requests.count
            for (index, request) in batch.requests.enumerated() {
                let sliced = slice(
                    result.response,
                    lowerTimelineBound: request.lowerTimelineBound,
                    limit: request.limit
                )
                request.continuation.resume(returning: TargetSequenceRequestResult(
                    result: PageResult(
                        response: sliced,
                        scannedRows: index == 0 ? result.scannedRows : 0,
                        scannedPages: index == 0 ? result.scannedPages : 0
                    ),
                    joinedWindow: index > 0,
                    coalescedRequestCount: requestCount
                ))
            }
        } catch {
            for request in batch.requests {
                request.continuation.resume(throwing: error)
            }
        }
    }

    private func slice(
        _ response: IMTimelinePageResponse,
        lowerTimelineBound: Int,
        limit: Int
    ) -> IMTimelinePageResponse {
        let safeLimit = max(1, limit)
        let itemsAfterLowerBound = response.items.filter {
            $0.timelineSequence > UInt64(lowerTimelineBound)
        }
        let pageItems = Array(itemsAfterLowerBound.prefix(safeLimit))
        return IMTimelinePageResponse(
            items: pageItems,
            hasMore: itemsAfterLowerBound.count > safeLimit || response.hasMore,
            nextAfterSequence: pageItems.last?.timelineSequence ?? UInt64(lowerTimelineBound)
        )
    }
}

actor IMTimelineReadMetrics {
    enum ReadKind: Sendable {
        case history
        case since
    }

    struct LatencyHistogram: Sendable, Equatable {
        var bucketUpperBoundsMilliseconds: [Int]
        var bucketCounts: [Int]
        var overflowCount: Int
        var sumMilliseconds: Int
        var count: Int
    }

    struct Snapshot: Sendable {
        var historyReadCount: Int = 0
        var sinceReadCount: Int = 0
        var errorCount: Int = 0
        var scanLimitExceededCount: Int = 0
        var itemCount: Int = 0
        var maxItems: Int = 0
        var scanRowCount: Int = 0
        var maxScanRows: Int = 0
        var scanPageCount: Int = 0
        var maxScanPages: Int = 0
        var totalMillis: Int = 0
        var maxMillis: Int = 0
        var sinceHotCacheHitCount: Int = 0
        var sinceHotCacheMissCount: Int = 0
        var sinceHotCacheUnsafeBypassCount: Int = 0
        var sinceHotCacheTargetSequenceBypassCount: Int = 0
        var sinceHotCacheInvalidationCount: Int = 0
        var sinceHotCacheInvalidatedEntryCount: Int = 0
        var sinceRecentCacheHitCount: Int = 0
        var sinceRecentCacheMissCount: Int = 0
        var sinceRecentCacheTargetSequenceBypassCount: Int = 0
        var sinceRecentCacheStoreCount: Int = 0
        var sinceRecentCacheInvalidationCount: Int = 0
        var sinceRecentCacheInvalidatedEntryCount: Int = 0
        var sinceVisibilitySafetyCacheHitCount: Int = 0
        var sinceVisibilitySafetyCacheMissCount: Int = 0
        var sinceVisibilitySafetyCacheJoinedInFlightCount: Int = 0
        var sinceVisibilitySafetyHiddenOverrideBypassCount: Int = 0
        var sinceVisibilitySafetyNoticeBypassCount: Int = 0
        var sinceResponseSingleflightJoinedCount: Int = 0
        var sinceResponseSingleflightNoticeBypassCount: Int = 0
        var sinceDistributedInvalidationPublishedCount: Int = 0
        var sinceDistributedInvalidationReceivedCount: Int = 0
        var sinceDistributedInvalidationErrorCount: Int = 0
        var sinceTargetSequenceRequestCount: Int = 0
        var sinceTargetSequenceEventualSatisfiedCount: Int = 0
        var sinceTargetSequenceStrongFallbackCount: Int = 0
        var sinceTargetSequenceStrongSatisfiedCount: Int = 0
        var sinceTargetSequenceStrongMissCount: Int = 0
        var sinceTargetSequenceErrorCount: Int = 0
        var sinceTargetSequenceSingleflightJoinedCount: Int = 0
        var sinceTargetSequenceWindowJoinedCount: Int = 0
        var historyLatencyHistogram = LatencyHistogram.empty
        var sinceLatencyHistogram = LatencyHistogram.empty
    }

    private static let latencyBucketUpperBoundsMilliseconds = [
        5,
        10,
        25,
        50,
        100,
        250,
        500,
        1_000,
        2_500,
        5_000,
        10_000,
        30_000
    ]

    private var snapshot = Snapshot()

    func recordRead(
        kind: ReadKind,
        itemCount: Int,
        scannedRows: Int,
        scannedPages: Int,
        elapsedMilliseconds: Int
    ) {
        let safeItemCount = max(0, itemCount)
        let safeScannedRows = max(0, scannedRows)
        let safeScannedPages = max(0, scannedPages)
        let safeElapsedMilliseconds = max(0, elapsedMilliseconds)
        switch kind {
        case .history:
            snapshot.historyReadCount += 1
            recordLatencyHistogram(&snapshot.historyLatencyHistogram, elapsedMilliseconds: safeElapsedMilliseconds)
        case .since:
            snapshot.sinceReadCount += 1
            recordLatencyHistogram(&snapshot.sinceLatencyHistogram, elapsedMilliseconds: safeElapsedMilliseconds)
        }
        snapshot.itemCount += safeItemCount
        snapshot.maxItems = max(snapshot.maxItems, safeItemCount)
        snapshot.scanRowCount += safeScannedRows
        snapshot.maxScanRows = max(snapshot.maxScanRows, safeScannedRows)
        snapshot.scanPageCount += safeScannedPages
        snapshot.maxScanPages = max(snapshot.maxScanPages, safeScannedPages)
        snapshot.totalMillis += safeElapsedMilliseconds
        snapshot.maxMillis = max(snapshot.maxMillis, safeElapsedMilliseconds)
    }

    func recordReadError(
        scannedRows: Int,
        scannedPages: Int,
        elapsedMilliseconds: Int,
        didExceedScanLimit: Bool
    ) {
        snapshot.errorCount += 1
        if didExceedScanLimit {
            snapshot.scanLimitExceededCount += 1
        }
        let safeScannedRows = max(0, scannedRows)
        let safeScannedPages = max(0, scannedPages)
        let safeElapsedMilliseconds = max(0, elapsedMilliseconds)
        snapshot.scanRowCount += safeScannedRows
        snapshot.maxScanRows = max(snapshot.maxScanRows, safeScannedRows)
        snapshot.scanPageCount += safeScannedPages
        snapshot.maxScanPages = max(snapshot.maxScanPages, safeScannedPages)
        snapshot.totalMillis += safeElapsedMilliseconds
        snapshot.maxMillis = max(snapshot.maxMillis, safeElapsedMilliseconds)
    }

    func recordSinceHotCacheHit() {
        snapshot.sinceHotCacheHitCount += 1
    }

    func recordSinceHotCacheMiss() {
        snapshot.sinceHotCacheMissCount += 1
    }

    func recordSinceHotCacheUnsafeBypass() {
        snapshot.sinceHotCacheUnsafeBypassCount += 1
    }

    func recordSinceHotCacheTargetSequenceBypass() {
        snapshot.sinceHotCacheTargetSequenceBypassCount += 1
    }

    func recordSinceHotCacheInvalidation(removedEntries: Int) {
        snapshot.sinceHotCacheInvalidationCount += 1
        snapshot.sinceHotCacheInvalidatedEntryCount += max(0, removedEntries)
    }

    func recordSinceRecentCacheHit() {
        snapshot.sinceRecentCacheHitCount += 1
    }

    func recordSinceRecentCacheMiss() {
        snapshot.sinceRecentCacheMissCount += 1
    }

    func recordSinceRecentCacheTargetSequenceBypass() {
        snapshot.sinceRecentCacheTargetSequenceBypassCount += 1
    }

    func recordSinceRecentCacheStore() {
        snapshot.sinceRecentCacheStoreCount += 1
    }

    func recordSinceRecentCacheInvalidation(removedEntries: Int) {
        snapshot.sinceRecentCacheInvalidationCount += 1
        snapshot.sinceRecentCacheInvalidatedEntryCount += max(0, removedEntries)
    }

    func recordSinceVisibilitySafetyCache(cacheHit: Bool, joinedInFlight: Bool, hasHiddenOverrides: Bool) {
        if cacheHit {
            snapshot.sinceVisibilitySafetyCacheHitCount += 1
        } else {
            snapshot.sinceVisibilitySafetyCacheMissCount += 1
        }
        if joinedInFlight {
            snapshot.sinceVisibilitySafetyCacheJoinedInFlightCount += 1
        }
        if hasHiddenOverrides {
            snapshot.sinceVisibilitySafetyHiddenOverrideBypassCount += 1
        }
    }

    func recordSinceVisibilitySafetyNoticeBypass() {
        snapshot.sinceVisibilitySafetyNoticeBypassCount += 1
    }

    func recordSinceResponseSingleflightJoined() {
        snapshot.sinceResponseSingleflightJoinedCount += 1
    }

    func recordSinceResponseSingleflightNoticeBypass() {
        snapshot.sinceResponseSingleflightNoticeBypassCount += 1
    }

    func recordSinceTargetSequenceSingleflightJoined() {
        snapshot.sinceTargetSequenceSingleflightJoinedCount += 1
    }

    func recordSinceTargetSequenceWindowJoined() {
        snapshot.sinceTargetSequenceWindowJoinedCount += 1
    }

    func recordSinceDistributedInvalidationPublished() {
        snapshot.sinceDistributedInvalidationPublishedCount += 1
    }

    func recordSinceDistributedInvalidationReceived() {
        snapshot.sinceDistributedInvalidationReceivedCount += 1
    }

    func recordSinceDistributedInvalidationError() {
        snapshot.sinceDistributedInvalidationErrorCount += 1
    }

    func recordSinceTargetSequenceRequest() {
        snapshot.sinceTargetSequenceRequestCount += 1
    }

    func recordSinceTargetSequenceEventualSatisfied() {
        snapshot.sinceTargetSequenceEventualSatisfiedCount += 1
    }

    func recordSinceTargetSequenceStrongFallback() {
        snapshot.sinceTargetSequenceStrongFallbackCount += 1
    }

    func recordSinceTargetSequenceStrongSatisfied() {
        snapshot.sinceTargetSequenceStrongSatisfiedCount += 1
    }

    func recordSinceTargetSequenceStrongMiss() {
        snapshot.sinceTargetSequenceStrongMissCount += 1
    }

    func recordSinceTargetSequenceError() {
        snapshot.sinceTargetSequenceErrorCount += 1
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }

    private func recordLatencyHistogram(
        _ histogram: inout LatencyHistogram,
        elapsedMilliseconds: Int
    ) {
        if histogram.bucketUpperBoundsMilliseconds.isEmpty {
            histogram = .empty
        }
        histogram.count += 1
        histogram.sumMilliseconds += elapsedMilliseconds
        for index in histogram.bucketUpperBoundsMilliseconds.indices
            where elapsedMilliseconds <= histogram.bucketUpperBoundsMilliseconds[index] {
            histogram.bucketCounts[index] += 1
        }
        if elapsedMilliseconds > (histogram.bucketUpperBoundsMilliseconds.last ?? 0) {
            histogram.overflowCount += 1
        }
    }
}

extension IMTimelineReadMetrics.LatencyHistogram {
    static var empty: IMTimelineReadMetrics.LatencyHistogram {
        IMTimelineReadMetrics.LatencyHistogram(
            bucketUpperBoundsMilliseconds: IMTimelineReadMetrics.latencyBucketUpperBoundsMilliseconds,
            bucketCounts: Array(repeating: 0, count: IMTimelineReadMetrics.latencyBucketUpperBoundsMilliseconds.count),
            overflowCount: 0,
            sumMilliseconds: 0,
            count: 0
        )
    }
}

private struct IMTimelineReadConfigurationStorageKey: StorageKey {
    typealias Value = IMTimelineReadConfiguration
}

private struct IMTimelineReadMetricsStorageKey: StorageKey {
    typealias Value = IMTimelineReadMetrics
}

private struct IMTimelineSinceHotCacheStorageKey: StorageKey {
    typealias Value = IMTimelineSinceHotCache
}

private struct IMTimelineSinceRecentCacheStorageKey: StorageKey {
    typealias Value = IMTimelineSinceRecentCache
}

private struct IMTimelineSinceVisibilitySafetyCacheStorageKey: StorageKey {
    typealias Value = IMTimelineSinceVisibilitySafetyCache
}

private struct IMTimelineSinceResponseCoalescerStorageKey: StorageKey {
    typealias Value = IMTimelineSinceResponseCoalescer
}

private struct IMTimelineSinceCacheInvalidationConfigurationStorageKey: StorageKey {
    typealias Value = IMTimelineSinceCacheInvalidationConfiguration
}

private struct IMTimelineSinceCacheInvalidationBusStorageKey: StorageKey {
    typealias Value = any IMTimelineSinceCacheInvalidating
}

extension Application {
    var timelineReadConfiguration: IMTimelineReadConfiguration {
        get {
            if let configuration = storage[IMTimelineReadConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMTimelineReadConfiguration.load(from: environment)
            storage[IMTimelineReadConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[IMTimelineReadConfigurationStorageKey.self] = newValue
        }
    }

    var timelineReadMetrics: IMTimelineReadMetrics {
        get {
            if let metrics = storage[IMTimelineReadMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMTimelineReadMetrics()
            storage[IMTimelineReadMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[IMTimelineReadMetricsStorageKey.self] = newValue
        }
    }

    var timelineSinceCacheInvalidationConfiguration: IMTimelineSinceCacheInvalidationConfiguration {
        get {
            if let configuration = storage[IMTimelineSinceCacheInvalidationConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMTimelineSinceCacheInvalidationConfiguration.load(from: environment)
            storage[IMTimelineSinceCacheInvalidationConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[IMTimelineSinceCacheInvalidationConfigurationStorageKey.self] = newValue
        }
    }

    var timelineSinceHotCache: IMTimelineSinceHotCache {
        get {
            if let cache = storage[IMTimelineSinceHotCacheStorageKey.self] {
                return cache
            }
            let cache = IMTimelineSinceHotCache()
            storage[IMTimelineSinceHotCacheStorageKey.self] = cache
            return cache
        }
        set {
            storage[IMTimelineSinceHotCacheStorageKey.self] = newValue
        }
    }

    var timelineSinceRecentCache: IMTimelineSinceRecentCache {
        get {
            if let cache = storage[IMTimelineSinceRecentCacheStorageKey.self] {
                return cache
            }
            let cache = IMTimelineSinceRecentCache()
            storage[IMTimelineSinceRecentCacheStorageKey.self] = cache
            return cache
        }
        set {
            storage[IMTimelineSinceRecentCacheStorageKey.self] = newValue
        }
    }

    var timelineSinceVisibilitySafetyCache: IMTimelineSinceVisibilitySafetyCache {
        get {
            if let cache = storage[IMTimelineSinceVisibilitySafetyCacheStorageKey.self] {
                return cache
            }
            let cache = IMTimelineSinceVisibilitySafetyCache()
            storage[IMTimelineSinceVisibilitySafetyCacheStorageKey.self] = cache
            return cache
        }
        set {
            storage[IMTimelineSinceVisibilitySafetyCacheStorageKey.self] = newValue
        }
    }

    var timelineSinceResponseCoalescer: IMTimelineSinceResponseCoalescer {
        get {
            if let coalescer = storage[IMTimelineSinceResponseCoalescerStorageKey.self] {
                return coalescer
            }
            let coalescer = IMTimelineSinceResponseCoalescer()
            storage[IMTimelineSinceResponseCoalescerStorageKey.self] = coalescer
            return coalescer
        }
        set {
            storage[IMTimelineSinceResponseCoalescerStorageKey.self] = newValue
        }
    }

    var timelineSinceCacheInvalidationBus: (any IMTimelineSinceCacheInvalidating)? {
        get {
            storage[IMTimelineSinceCacheInvalidationBusStorageKey.self]
        }
        set {
            storage[IMTimelineSinceCacheInvalidationBusStorageKey.self] = newValue
        }
    }

    func invalidateTimelineSinceHotCache(conversationID: UUID) {
        invalidateTimelineSinceHotCacheLocally(conversationID: conversationID)
        guard let bus = timelineSinceCacheInvalidationBus else {
            return
        }
        Task {
            await bus.publish(conversationID: conversationID)
        }
    }

    @discardableResult
    func invalidateTimelineSinceHotCacheLocally(conversationID: UUID) -> Int {
        let removedEntries = timelineSinceHotCache.invalidate(conversationID: conversationID)
        let removedRecentEntries = timelineSinceRecentCache.invalidate(conversationID: conversationID)
        Task {
            _ = await timelineSinceVisibilitySafetyCache.invalidate(conversationID: conversationID)
            await timelineSinceResponseCoalescer.cancel(conversationID: conversationID)
            await timelineReadMetrics.recordSinceHotCacheInvalidation(removedEntries: removedEntries)
            await timelineReadMetrics.recordSinceRecentCacheInvalidation(removedEntries: removedRecentEntries)
        }
        return removedEntries + removedRecentEntries
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
