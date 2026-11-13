import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Account-store search facade. Requests carry their own cursor, so separate windows
/// never replace one another's query. The existing index owns generation and privacy rules.
public actor V2SearchService {
    private let store: GRDBV2LocalSyncStore
    private let operations = V2ResourceOperationScope(limit: 128)
    private var closed = false
    private var closing: Task<Void, Never>?

    public init(store: GRDBV2LocalSyncStore) { self.store = store }

    public func search(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        try await perform { [store] in try await store.messageSearch.searchMessages(request) }
    }
    public func conversationContext(in room: RoomID) async throws -> V2ClientConversationLookupContext? {
        try await perform { [store] in try await store.conversationLookupContexts(for: [room])[room] }
    }
    public func progress() async throws -> V2MessageSearchIndexProgress {
        try await perform { [store] in try await store.messageSearch.messageSearchIndexProgress() }
    }
    public func updates() async -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        guard !closed else {
            return AsyncThrowingStream { $0.finish(throwing: V2MessageSearchError.closed) }
        }
        // The index itself owns and drains every subscriber on close.
        return await store.messageSearch.messageSearchIndexUpdates()
    }
    public func startIndexing() async { guard !closed else { return }; await store.messageSearch.startIndexing() }
    public func stopIndexing() async { await store.messageSearch.stopIndexing() }
    private func perform<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw V2MessageSearchError.closed }
        let value = try await operations.run(body)
        guard !closed else { throw V2MessageSearchError.closed }
        try Task.checkCancellation()
        return value
    }
    public func close() async {
        if let closing { await closing.value; return }
        closed = true
        let task = Task { [operations, store] in
            await operations.close()
            await store.messageSearch.close()
        }
        closing = task; await task.value
    }
}
