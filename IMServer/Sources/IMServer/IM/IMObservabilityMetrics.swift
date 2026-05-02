import Vapor

actor IMHTTPMetrics {
    struct Snapshot: Sendable {
        var requestCount: Int = 0
        var failedRequestCount: Int = 0
        var totalLatencyMillis: Int = 0
        var maxLatencyMillis: Int = 0
        var lastPath: String?
        var lastStatusCode: Int?

        var averageLatencyMillis: Int {
            guard requestCount > 0 else {
                return 0
            }
            return totalLatencyMillis / requestCount
        }
    }

    private var snapshot = Snapshot()

    func record(path: String, statusCode: Int, durationMillis: Int, didFail: Bool) {
        snapshot.requestCount += 1
        if didFail || statusCode >= 500 {
            snapshot.failedRequestCount += 1
        }
        snapshot.totalLatencyMillis += max(0, durationMillis)
        snapshot.maxLatencyMillis = max(snapshot.maxLatencyMillis, durationMillis)
        snapshot.lastPath = path
        snapshot.lastStatusCode = statusCode
    }

    func currentSnapshot() -> Snapshot {
        snapshot
    }
}

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

struct IMHTTPMetricsMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let start = Date()
        do {
            let response = try await next.respond(to: request)
            await request.application.httpMetrics.record(
                path: request.url.path,
                statusCode: Int(response.status.code),
                durationMillis: Self.elapsedMillis(since: start),
                didFail: false
            )
            return response
        } catch {
            await request.application.httpMetrics.record(
                path: request.url.path,
                statusCode: 500,
                durationMillis: Self.elapsedMillis(since: start),
                didFail: true
            )
            throw error
        }
    }

    private static func elapsedMillis(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}

private struct IMHTTPMetricsStorageKey: StorageKey {
    typealias Value = IMHTTPMetrics
}

private struct IMDatabaseMetricsStorageKey: StorageKey {
    typealias Value = IMDatabaseMetrics
}

private struct IMStreamMetricsStorageKey: StorageKey {
    typealias Value = IMStreamMetrics
}

extension Application {
    var httpMetrics: IMHTTPMetrics {
        get {
            if let metrics = storage[IMHTTPMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMHTTPMetrics()
            storage[IMHTTPMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMHTTPMetricsStorageKey.self] = newValue }
    }

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
