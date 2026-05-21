import Vapor

struct AIStreamingRequest: Sendable {
    let conversationID: UUID
    let prompt: String
    let userID: UUID
    let modelID: String
    let estimatedCostUnits: Int
}

protocol AIStreamingProvider: Sendable {
    func streamText(for request: AIStreamingRequest) -> AsyncThrowingStream<String, any Error>
}

struct MockAIStreamingProvider: AIStreamingProvider {
    func streamText(for request: AIStreamingRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = "AI: \(request.prompt)"
                    let chunks = output.split(separator: " ", omittingEmptySubsequences: false)
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        if index > 0 {
                            continuation.yield(" ")
                        }
                        continuation.yield(String(chunk))
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

struct ActiveAIMessageStreamContext: Sendable, Equatable {
    let streamID: String
    let conversationID: UUID
    let messageID: UUID
    let userID: UUID
    let recipientUserIDs: [UUID]
}

actor ActiveAIMessageStreamRegistry {
    private struct ActiveStream: Sendable {
        let context: ActiveAIMessageStreamContext
        var task: Task<Void, Never>?
    }

    private var streams: [String: ActiveStream] = [:]

    func register(context: ActiveAIMessageStreamContext) {
        streams[context.streamID] = ActiveStream(context: context, task: nil)
    }

    func attach(task: Task<Void, Never>, streamID: String) {
        guard var stream = streams[streamID] else {
            task.cancel()
            return
        }
        stream.task = task
        streams[streamID] = stream
    }

    func cancel(streamID: String) -> Task<Void, Never>? {
        streams.removeValue(forKey: streamID)?.task
    }

    func finish(streamID: String) {
        streams.removeValue(forKey: streamID)
    }

    func context(streamID: String) -> ActiveAIMessageStreamContext? {
        streams[streamID]?.context
    }
}

private struct AIStreamingProviderStorageKey: StorageKey {
    typealias Value = any AIStreamingProvider
}

private struct ActiveAIMessageStreamRegistryStorageKey: StorageKey {
    typealias Value = ActiveAIMessageStreamRegistry
}

extension Application {
    var aiStreamingProvider: any AIStreamingProvider {
        get {
            if let provider = storage[AIStreamingProviderStorageKey.self] {
                return provider
            }
            let provider = MockAIStreamingProvider()
            storage[AIStreamingProviderStorageKey.self] = provider
            return provider
        }
        set { storage[AIStreamingProviderStorageKey.self] = newValue }
    }

    var activeAIMessageStreamRegistry: ActiveAIMessageStreamRegistry {
        get {
            if let registry = storage[ActiveAIMessageStreamRegistryStorageKey.self] {
                return registry
            }
            let registry = ActiveAIMessageStreamRegistry()
            storage[ActiveAIMessageStreamRegistryStorageKey.self] = registry
            return registry
        }
        set { storage[ActiveAIMessageStreamRegistryStorageKey.self] = newValue }
    }
}
