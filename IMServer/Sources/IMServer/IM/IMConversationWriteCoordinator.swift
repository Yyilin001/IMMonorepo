import Vapor

actor IMConversationWriteCoordinator {
    private var inFlight: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var depths: [UUID: Int] = [:]

    func run<T: Sendable>(
        conversationID: UUID,
        app: Application?,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        depths[conversationID, default: 0] += 1
        await app?.messageWriteMetrics.recordWriteQueueDepth(depths[conversationID] ?? 0)
        await acquire(conversationID)

        do {
            let result = try await operation()
            await release(conversationID, app: app)
            return result
        } catch {
            await release(conversationID, app: app)
            throw error
        }
    }

    private func acquire(_ conversationID: UUID) async {
        if !inFlight.contains(conversationID) {
            inFlight.insert(conversationID)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[conversationID, default: []].append(continuation)
        }
        inFlight.insert(conversationID)
    }

    private func release(_ conversationID: UUID, app: Application?) async {
        depths[conversationID, default: 1] -= 1
        if depths[conversationID] ?? 0 <= 0 {
            depths[conversationID] = nil
        }
        await app?.messageWriteMetrics.recordWriteQueueDepth(depths[conversationID] ?? 0)

        if var queue = waiters[conversationID], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[conversationID] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            inFlight.remove(conversationID)
        }
    }
}
