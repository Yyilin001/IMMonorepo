import Vapor

final class IMMessagePersistenceDiagnostics: @unchecked Sendable {
    private let startedAt = Date()
    private let lock = NSLock()
    private var marks: [String: Int] = [:]
    private var recipientCount = 0

    func measure<T>(
        _ name: String,
        operation: () async throws -> T
    ) async throws -> T {
        let startedAt = Date()
        let result = try await operation()
        record(name, startedAt: startedAt)
        return result
    }

    func record(_ name: String, startedAt: Date) {
        lock.lock()
        marks[name, default: 0] += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        lock.unlock()
    }

    func recordRecipientCount(_ value: Int) {
        lock.lock()
        recipientCount = max(recipientCount, value)
        lock.unlock()
    }

    func logIfSlow(
        app: Application?,
        conversationID: UUID,
        messageCount: Int
    ) {
        guard let app else {
            return
        }
        let totalMillis = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let threshold = max(
            0,
            Environment.get("IM_MESSAGE_PERSISTENCE_SLOW_LOG_MS").flatMap(Int.init(_:)) ?? 1_000
        )
        guard threshold == 0 || totalMillis >= threshold else {
            return
        }

        lock.lock()
        let capturedMarks = marks
        let capturedRecipientCount = recipientCount
        lock.unlock()

        var metadata: Logger.Metadata = [
            "conversationID": .string(conversationID.uuidString),
            "messageCount": .stringConvertible(messageCount),
            "recipientCount": .stringConvertible(capturedRecipientCount),
            "totalMs": .stringConvertible(totalMillis)
        ]
        for (name, millis) in capturedMarks.sorted(by: { $0.key < $1.key }) {
            metadata["\(name)Ms"] = .stringConvertible(millis)
        }
        app.logger.warning("IM message persistence slow", metadata: metadata)
    }
}
