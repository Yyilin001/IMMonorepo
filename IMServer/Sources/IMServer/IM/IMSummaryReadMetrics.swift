import Vapor

actor IMSummaryReadMetrics {
    enum ReadPath: Sendable {
        case joined
        case fluent
    }

    struct Snapshot: Sendable {
        var summaryReadCount: Int = 0
        var summaryReadErrorCount: Int = 0
        var summaryReadTotalMillis: Int = 0
        var summaryReadMaxMillis: Int = 0
        var listReadCount: Int = 0
        var listReadErrorCount: Int = 0
        var listReadJoinedCount: Int = 0
        var listReadFluentCount: Int = 0
        var listReadFallbackCount: Int = 0
        var listReadItemCount: Int = 0
        var listReadMaxItems: Int = 0
        var listReadTotalMillis: Int = 0
        var listReadMaxMillis: Int = 0
        var changesReadCount: Int = 0
        var changesReadErrorCount: Int = 0
        var changesReadJoinedCount: Int = 0
        var changesReadFluentCount: Int = 0
        var changesReadFallbackCount: Int = 0
        var changesReadUpsertCount: Int = 0
        var changesReadRemovedCount: Int = 0
        var changesReadMaxItems: Int = 0
        var changesReadTotalMillis: Int = 0
        var changesReadMaxMillis: Int = 0
    }

    private var snapshot = Snapshot()

    func recordSummaryRead(elapsedMilliseconds: Int) {
        snapshot.summaryReadCount += 1
        snapshot.summaryReadTotalMillis += max(0, elapsedMilliseconds)
        snapshot.summaryReadMaxMillis = max(snapshot.summaryReadMaxMillis, elapsedMilliseconds)
    }

    func recordSummaryReadError(elapsedMilliseconds: Int) {
        snapshot.summaryReadErrorCount += 1
        snapshot.summaryReadTotalMillis += max(0, elapsedMilliseconds)
        snapshot.summaryReadMaxMillis = max(snapshot.summaryReadMaxMillis, elapsedMilliseconds)
    }

    func recordListRead(
        path: ReadPath,
        itemCount: Int,
        elapsedMilliseconds: Int,
        usedFallback: Bool
    ) {
        snapshot.listReadCount += 1
        switch path {
        case .joined:
            snapshot.listReadJoinedCount += 1
        case .fluent:
            snapshot.listReadFluentCount += 1
        }
        if usedFallback {
            snapshot.listReadFallbackCount += 1
        }
        let safeItemCount = max(0, itemCount)
        snapshot.listReadItemCount += safeItemCount
        snapshot.listReadMaxItems = max(snapshot.listReadMaxItems, safeItemCount)
        snapshot.listReadTotalMillis += max(0, elapsedMilliseconds)
        snapshot.listReadMaxMillis = max(snapshot.listReadMaxMillis, elapsedMilliseconds)
    }

    func recordListReadError(elapsedMilliseconds: Int) {
        snapshot.listReadErrorCount += 1
        snapshot.listReadTotalMillis += max(0, elapsedMilliseconds)
        snapshot.listReadMaxMillis = max(snapshot.listReadMaxMillis, elapsedMilliseconds)
    }

    func recordChangesRead(
        path: ReadPath,
        upsertCount: Int,
        removedCount: Int,
        elapsedMilliseconds: Int,
        usedFallback: Bool
    ) {
        snapshot.changesReadCount += 1
        switch path {
        case .joined:
            snapshot.changesReadJoinedCount += 1
        case .fluent:
            snapshot.changesReadFluentCount += 1
        }
        if usedFallback {
            snapshot.changesReadFallbackCount += 1
        }
        let safeUpsertCount = max(0, upsertCount)
        let safeRemovedCount = max(0, removedCount)
        snapshot.changesReadUpsertCount += safeUpsertCount
        snapshot.changesReadRemovedCount += safeRemovedCount
        snapshot.changesReadMaxItems = max(
            snapshot.changesReadMaxItems,
            safeUpsertCount + safeRemovedCount
        )
        snapshot.changesReadTotalMillis += max(0, elapsedMilliseconds)
        snapshot.changesReadMaxMillis = max(snapshot.changesReadMaxMillis, elapsedMilliseconds)
    }

    func recordChangesReadError(elapsedMilliseconds: Int) {
        snapshot.changesReadErrorCount += 1
        snapshot.changesReadTotalMillis += max(0, elapsedMilliseconds)
        snapshot.changesReadMaxMillis = max(snapshot.changesReadMaxMillis, elapsedMilliseconds)
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

private struct IMSummaryReadMetricsStorageKey: StorageKey {
    typealias Value = IMSummaryReadMetrics
}

extension Application {
    var summaryReadMetrics: IMSummaryReadMetrics {
        get {
            if let metrics = storage[IMSummaryReadMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMSummaryReadMetrics()
            storage[IMSummaryReadMetricsStorageKey.self] = metrics
            return metrics
        }
        set {
            storage[IMSummaryReadMetricsStorageKey.self] = newValue
        }
    }
}
