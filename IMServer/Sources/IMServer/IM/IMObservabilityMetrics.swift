import Vapor

actor IMDatabaseMetrics {
    struct Snapshot: Sendable {
        var operationCount: Int = 0
        var failedOperationCount: Int = 0
        var totalLatencyMillis: Int = 0
        var maxLatencyMillis: Int = 0
        var lastOperation: String?

        var averageLatencyMillis: Int {
            guard operationCount > 0 else {
                return 0
            }
            return totalLatencyMillis / operationCount
        }
    }

    private var snapshot = Snapshot()

    func record(operation: String, durationMillis: Int, didFail: Bool = false) {
        snapshot.operationCount += 1
        if didFail {
            snapshot.failedOperationCount += 1
        }
        snapshot.totalLatencyMillis += max(0, durationMillis)
        snapshot.maxLatencyMillis = max(snapshot.maxLatencyMillis, durationMillis)
        snapshot.lastOperation = operation
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

actor IMStreamMetrics {
    struct Snapshot: Sendable {
        var consumedEvents: Int = 0
        var duplicateEvents: Int = 0
        var failedEvents: Int = 0
        var deadLetterPublishedEvents: Int = 0
        var lastConsumerGroupID: String?
    }

    private var snapshot = Snapshot()

    func recordConsumed(groupID: String) {
        snapshot.consumedEvents += 1
        snapshot.lastConsumerGroupID = groupID
    }

    func recordDuplicate(groupID: String) {
        snapshot.duplicateEvents += 1
        snapshot.lastConsumerGroupID = groupID
    }

    func recordFailed(groupID: String) {
        snapshot.failedEvents += 1
        snapshot.lastConsumerGroupID = groupID
    }

    func recordDeadLetterPublished(groupID: String) {
        snapshot.deadLetterPublishedEvents += 1
        snapshot.lastConsumerGroupID = groupID
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

private struct IMDatabaseMetricsStorageKey: StorageKey {
    typealias Value = IMDatabaseMetrics
}

private struct IMStreamMetricsStorageKey: StorageKey {
    typealias Value = IMStreamMetrics
}

extension Application {
    var databaseMetrics: IMDatabaseMetrics {
        get {
            if let metrics = storage[IMDatabaseMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMDatabaseMetrics()
            storage[IMDatabaseMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMDatabaseMetricsStorageKey.self] = newValue }
    }

    var streamMetrics: IMStreamMetrics {
        get {
            if let metrics = storage[IMStreamMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMStreamMetrics()
            storage[IMStreamMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMStreamMetricsStorageKey.self] = newValue }
    }
}
