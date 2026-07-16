import Vapor

actor ConversationShardMigrationMetrics {
    struct Snapshot: Sendable {
        var copyAttemptCount: Int = 0
        var copySuccessCount: Int = 0
        var copyFailureCount: Int = 0
        var verifyAttemptCount: Int = 0
        var verifySuccessCount: Int = 0
        var verifyFailureCount: Int = 0
        var remotePageAttemptCount: Int = 0
        var remotePageSuccessCount: Int = 0
        var remotePageFailureCount: Int = 0
        var remotePageRecordCount: Int = 0
        var remotePageByteCount: Int = 0
        var remotePageTotalMillis: Int = 0
        var remotePageMaxMillis: Int = 0
    }

    private var snapshot = Snapshot()

    func recordCopyAttempt() { snapshot.copyAttemptCount += 1 }
    func recordCopySuccess() { snapshot.copySuccessCount += 1 }
    func recordCopyFailure() { snapshot.copyFailureCount += 1 }
    func recordVerifyAttempt() { snapshot.verifyAttemptCount += 1 }
    func recordVerifySuccess() { snapshot.verifySuccessCount += 1 }
    func recordVerifyFailure() { snapshot.verifyFailureCount += 1 }

    func recordRemotePageAttempt(recordCount: Int, byteCount: Int) {
        snapshot.remotePageAttemptCount += 1
        snapshot.remotePageRecordCount += max(0, recordCount)
        snapshot.remotePageByteCount += max(0, byteCount)
    }

    func recordRemotePageSuccess(elapsedMilliseconds: Int) {
        snapshot.remotePageSuccessCount += 1
        recordRemotePageLatency(elapsedMilliseconds)
    }

    func recordRemotePageFailure(elapsedMilliseconds: Int) {
        snapshot.remotePageFailureCount += 1
        recordRemotePageLatency(elapsedMilliseconds)
    }

    func currentSnapshot() -> Snapshot { snapshot }

    private func recordRemotePageLatency(_ elapsedMilliseconds: Int) {
        let safeElapsed = max(0, elapsedMilliseconds)
        snapshot.remotePageTotalMillis += safeElapsed
        snapshot.remotePageMaxMillis = max(snapshot.remotePageMaxMillis, safeElapsed)
    }
}

private struct ConversationShardMigrationMetricsStorageKey: StorageKey {
    typealias Value = ConversationShardMigrationMetrics
}

extension Application {
    var conversationShardMigrationMetrics: ConversationShardMigrationMetrics {
        get {
            if let metrics = storage[ConversationShardMigrationMetricsStorageKey.self] {
                return metrics
            }
            let metrics = ConversationShardMigrationMetrics()
            storage[ConversationShardMigrationMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[ConversationShardMigrationMetricsStorageKey.self] = newValue }
    }
}
