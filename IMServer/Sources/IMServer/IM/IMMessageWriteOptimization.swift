import Fluent
import SQLKit
import Vapor

struct IMSequenceAllocationConfiguration: Sendable {
    enum Mode: String, Sendable {
        case legacy
        case block
    }

    let mode: Mode
    let blockSize: Int

    static func load(from environment: Environment) -> IMSequenceAllocationConfiguration {
        IMSequenceAllocationConfiguration(
            mode: Environment.get("IM_SEQUENCE_ALLOCATION_MODE")
                .flatMap(Mode.init(rawValue:)) ?? .legacy,
            blockSize: max(1, Environment.get("IM_SEQUENCE_BLOCK_SIZE").flatMap(Int.init(_:)) ?? 256)
        )
    }
}

struct IMCommandOwnerRoutingConfiguration: Sendable {
    struct Node: Sendable {
        let id: String
        let baseURL: String
    }

    let nodeID: String?
    let nodes: [Node]
    let sharedSecret: String?

    var isEnabled: Bool {
        !nodes.isEmpty
    }

    static func load(from environment: Environment) -> IMCommandOwnerRoutingConfiguration {
        let nodes = (Environment.get("IM_COMMAND_NODE_URLS") ?? "")
            .split(separator: ",")
            .compactMap { raw -> Node? in
                let parts = raw.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !url.isEmpty else { return nil }
                return Node(id: id, baseURL: url)
            }
        return IMCommandOwnerRoutingConfiguration(
            nodeID: Environment.get("IM_COMMAND_NODE_ID"),
            nodes: nodes,
            sharedSecret: Environment.get("IM_COMMAND_INTERNAL_SHARED_SECRET")
                ?? Environment.get("IM_INTERNAL_SHARED_SECRET")
        )
    }

    func owner(for conversationID: UUID) -> Node? {
        guard isEnabled else { return nil }
        let key = conversationID.uuidString.lowercased()
        return nodes.max { lhs, rhs in
            stableScore(key: key, nodeID: lhs.id) < stableScore(key: key, nodeID: rhs.id)
        }
    }

    func isLocalOwner(for conversationID: UUID) -> Bool {
        guard let owner = owner(for: conversationID) else { return true }
        return owner.id == nodeID
    }

    private func stableScore(key: String, nodeID: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key)|\(nodeID)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

struct IMConversationMemberCacheConfiguration: Sendable {
    let ttlSeconds: Int

    var isEnabled: Bool { ttlSeconds > 0 }

    static func load(from environment: Environment) -> IMConversationMemberCacheConfiguration {
        IMConversationMemberCacheConfiguration(
            ttlSeconds: max(0, Environment.get("IM_CONVERSATION_MEMBER_CACHE_TTL_SECONDS").flatMap(Int.init(_:)) ?? 10)
        )
    }
}

struct IMMessageWriteBatchConfiguration: Sendable {
    let enabled: Bool
    let maxSize: Int
    let maxDelayMillis: Int
    let maxQueueDepthPerConversation: Int

    var isEnabled: Bool {
        enabled && maxSize > 1 && maxDelayMillis > 0
    }

    static func load(from environment: Environment) -> IMMessageWriteBatchConfiguration {
        let rawEnabled = Environment.get("IM_MESSAGE_WRITE_BATCH_ENABLED")?.lowercased()
        let enabled = rawEnabled.map { ["1", "true", "yes", "on"].contains($0) } ?? false
        return IMMessageWriteBatchConfiguration(
            enabled: enabled,
            maxSize: max(2, Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_SIZE").flatMap(Int.init(_:)) ?? 32),
            maxDelayMillis: max(1, Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_DELAY_MS").flatMap(Int.init(_:)) ?? 10),
            maxQueueDepthPerConversation: max(
                1,
                Environment.get("IM_MESSAGE_WRITE_BATCH_MAX_QUEUE_DEPTH").flatMap(Int.init(_:)) ?? 1_024
            )
        )
    }
}

struct IMCachedConversationMembership: Sendable {
    let conversationKind: IMConversationKind
    let directMessagingState: IMDirectMessagingState
    let memberUserIDs: [UUID]
}

actor IMConversationMemberCache {
    private struct Entry {
        let context: IMCachedConversationMembership
        let expiresAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    func value(for conversationID: UUID, now: Date = Date()) -> IMCachedConversationMembership? {
        guard let entry = entries[conversationID] else { return nil }
        guard entry.expiresAt > now else {
            entries[conversationID] = nil
            return nil
        }
        return entry.context
    }

    func store(_ context: IMCachedConversationMembership, for conversationID: UUID, ttlSeconds: Int, now: Date = Date()) {
        guard ttlSeconds > 0 else { return }
        entries[conversationID] = Entry(
            context: context,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlSeconds))
        )
    }

    func invalidate(conversationID: UUID) {
        entries[conversationID] = nil
    }
}

actor IMDirectConversationPairCache {
    private struct Entry {
        let conversationIDs: [UUID]
        let expiresAt: Date
    }

    private let ttlSeconds: TimeInterval
    private var entries: [String: Entry] = [:]
    private var keysByConversationID: [UUID: Set<String>] = [:]

    init(ttlSeconds: TimeInterval = 5) {
        self.ttlSeconds = ttlSeconds
    }

    func conversationIDs(lhs: UUID, rhs: UUID, now: Date = Date()) -> [UUID]? {
        let key = Self.key(lhs: lhs, rhs: rhs)
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            removeEntry(for: key)
            return nil
        }
        return entry.conversationIDs
    }

    func store(_ conversationIDs: [UUID], lhs: UUID, rhs: UUID, now: Date = Date()) {
        let key = Self.key(lhs: lhs, rhs: rhs)
        removeEntry(for: key)
        entries[key] = Entry(
            conversationIDs: conversationIDs,
            expiresAt: now.addingTimeInterval(ttlSeconds)
        )
        for conversationID in conversationIDs {
            keysByConversationID[conversationID, default: []].insert(key)
        }
    }

    func invalidate(conversationID: UUID) {
        let keys = keysByConversationID[conversationID] ?? []
        for key in keys {
            removeEntry(for: key)
        }
        keysByConversationID[conversationID] = nil
    }

    private func removeEntry(for key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        for conversationID in entry.conversationIDs {
            keysByConversationID[conversationID]?.remove(key)
            if keysByConversationID[conversationID]?.isEmpty == true {
                keysByConversationID[conversationID] = nil
            }
        }
    }

    private static func key(lhs: UUID, rhs: UUID) -> String {
        [lhs.uuidString.lowercased(), rhs.uuidString.lowercased()].sorted().joined(separator: ":")
    }
}

actor IMMessageWriteBatcher {
    struct Item: Sendable {
        let message: IMPreparedIncomingMessage
    }

    private struct QueuedItem {
        let item: Item
        let continuation: CheckedContinuation<IMRealtimeMessagePersistenceResult, any Error>
    }

    private var queues: [UUID: [QueuedItem]] = [:]
    private var scheduledConversationIDs: Set<UUID> = []
    private var processingConversationIDs: Set<UUID> = []

    func enqueue(
        _ item: Item,
        conversationID: UUID,
        app: Application,
        configuration: IMMessageWriteBatchConfiguration
    ) async throws -> IMRealtimeMessagePersistenceResult {
        try await withCheckedThrowingContinuation { continuation in
            let currentDepth = queues[conversationID]?.count ?? 0
            guard currentDepth < configuration.maxQueueDepthPerConversation else {
                continuation.resume(throwing: IMRealtimeMessageError.messageWriteQueueFull)
                Task {
                    await app.messageWriteMetrics.recordWriteQueueRejected()
                    await app.messageWriteMetrics.recordWriteQueueDepth(currentDepth)
                }
                return
            }

            queues[conversationID, default: []].append(
                QueuedItem(item: item, continuation: continuation)
            )
            let depth = queues[conversationID]?.count ?? 0
            Task {
                await app.messageWriteMetrics.recordWriteQueueDepth(depth)
            }

            if queues[conversationID, default: []].count >= configuration.maxSize {
                Task {
                    await flush(conversationID: conversationID, app: app, configuration: configuration)
                }
            } else {
                scheduleFlushIfNeeded(conversationID: conversationID, app: app, configuration: configuration)
            }
        }
    }

    private func scheduleFlushIfNeeded(
        conversationID: UUID,
        app: Application,
        configuration: IMMessageWriteBatchConfiguration
    ) {
        guard !scheduledConversationIDs.contains(conversationID),
              !processingConversationIDs.contains(conversationID)
        else {
            return
        }

        scheduledConversationIDs.insert(conversationID)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(configuration.maxDelayMillis) * 1_000_000)
            await flush(conversationID: conversationID, app: app, configuration: configuration)
        }
    }

    private func flush(
        conversationID: UUID,
        app: Application,
        configuration: IMMessageWriteBatchConfiguration
    ) async {
        guard !processingConversationIDs.contains(conversationID) else {
            return
        }
        scheduledConversationIDs.remove(conversationID)
        guard var queue = queues[conversationID], !queue.isEmpty else {
            return
        }

        processingConversationIDs.insert(conversationID)
        let batch = Array(queue.prefix(configuration.maxSize))
        queue.removeFirst(batch.count)
        queues[conversationID] = queue.isEmpty ? nil : queue
        await app.messageWriteMetrics.recordWriteQueueDepth(queue.count)

        do {
            let results = try await IMRealtimeMessageService(app: app)
                .persistOwnedIncomingMessagesBatch(
                    batch.map(\.item.message),
                    conversationID: conversationID
                )
            for (queued, result) in zip(batch, results) {
                queued.continuation.resume(returning: result)
            }
            await app.messageWriteMetrics.recordMessageWriteBatch(messageCount: batch.count)
        } catch {
            for queued in batch {
                queued.continuation.resume(throwing: error)
            }
        }

        processingConversationIDs.remove(conversationID)
        if queues[conversationID]?.isEmpty == false {
            scheduleFlushIfNeeded(conversationID: conversationID, app: app, configuration: configuration)
        }
    }

}

actor IMSequenceBlockAllocator {
    private struct Block {
        var next: Int
        let end: Int
    }

    private var blocks: [UUID: Block] = [:]

    func nextSequences(
        count: Int,
        conversationID: UUID,
        blockSize: Int,
        updatedAt: Date,
        on database: any Database,
        app: Application?
    ) async throws -> [Int] {
        guard count > 0 else {
            return []
        }

        var sequences: [Int] = []
        sequences.reserveCapacity(count)
        for _ in 0..<count {
            sequences.append(
                try await nextSequence(
                    conversationID: conversationID,
                    blockSize: blockSize,
                    updatedAt: updatedAt,
                    on: database,
                    app: app
                )
            )
        }
        return sequences
    }

    func nextSequence(
        conversationID: UUID,
        blockSize: Int,
        updatedAt: Date,
        on database: any Database,
        app: Application?
    ) async throws -> Int {
        if var block = blocks[conversationID], block.next <= block.end {
            let sequence = block.next
            block.next += 1
            blocks[conversationID] = block
            await app?.messageWriteMetrics.recordSequenceBlockRemaining(max(0, block.end - block.next + 1))
            return sequence
        }

        do {
            let reserved = try await ConversationSequenceAllocator(db: database).reserve(
                count: blockSize,
                conversationID: conversationID,
                updatedAt: updatedAt
            )
            guard let start = reserved.first, let end = reserved.last else {
                throw Abort(.notFound, reason: "会话不存在。")
            }
            blocks[conversationID] = Block(next: start + 1, end: end)
            await app?.messageWriteMetrics.recordSequenceBlockReserved()
            await app?.messageWriteMetrics.recordSequenceBlockRemaining(blockSize - 1)
            return start
        } catch {
            await app?.messageWriteMetrics.recordSequenceBlockReserveFailed()
            throw error
        }
    }
}

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

actor IMMessageWriteMetrics {
    struct Snapshot: Sendable {
        var sequenceBlocksReserved: Int = 0
        var sequenceBlockReserveFailures: Int = 0
        var sequenceBlockRemaining: Int = 0
        var ownerForwardCount: Int = 0
        var ownerForwardFailureCount: Int = 0
        var writeQueueDepth: Int = 0
        var memberCacheHits: Int = 0
        var memberCacheMisses: Int = 0
        var messageWriteBatches: Int = 0
        var messageWriteBatchMessages: Int = 0
        var writeQueueRejected: Int = 0
    }

    private var snapshot = Snapshot()

    func recordSequenceBlockReserved() { snapshot.sequenceBlocksReserved += 1 }
    func recordSequenceBlockReserveFailed() { snapshot.sequenceBlockReserveFailures += 1 }
    func recordSequenceBlockRemaining(_ value: Int) { snapshot.sequenceBlockRemaining = value }
    func recordOwnerForwarded() { snapshot.ownerForwardCount += 1 }
    func recordOwnerForwardFailed() { snapshot.ownerForwardFailureCount += 1 }
    func recordWriteQueueDepth(_ value: Int) { snapshot.writeQueueDepth = value }
    func recordMemberCacheHit() { snapshot.memberCacheHits += 1 }
    func recordMemberCacheMiss() { snapshot.memberCacheMisses += 1 }
    func recordWriteQueueRejected() { snapshot.writeQueueRejected += 1 }
    func recordMessageWriteBatch(messageCount: Int) {
        snapshot.messageWriteBatches += 1
        snapshot.messageWriteBatchMessages += messageCount
    }
    func currentSnapshot() -> Snapshot { snapshot }
}

private struct IMSequenceAllocationConfigurationStorageKey: StorageKey {
    typealias Value = IMSequenceAllocationConfiguration
}

private struct IMCommandOwnerRoutingConfigurationStorageKey: StorageKey {
    typealias Value = IMCommandOwnerRoutingConfiguration
}

private struct IMConversationMemberCacheConfigurationStorageKey: StorageKey {
    typealias Value = IMConversationMemberCacheConfiguration
}

private struct IMMessageWriteBatchConfigurationStorageKey: StorageKey {
    typealias Value = IMMessageWriteBatchConfiguration
}

private struct IMSequenceBlockAllocatorStorageKey: StorageKey {
    typealias Value = IMSequenceBlockAllocator
}

private struct IMMessageWriteBatcherStorageKey: StorageKey {
    typealias Value = IMMessageWriteBatcher
}

private struct IMConversationWriteCoordinatorStorageKey: StorageKey {
    typealias Value = IMConversationWriteCoordinator
}

private struct IMConversationMemberCacheStorageKey: StorageKey {
    typealias Value = IMConversationMemberCache
}

private struct IMDirectConversationPairCacheStorageKey: StorageKey {
    typealias Value = IMDirectConversationPairCache
}

private struct IMMessageWriteMetricsStorageKey: StorageKey {
    typealias Value = IMMessageWriteMetrics
}

extension Application {
    var sequenceAllocationConfiguration: IMSequenceAllocationConfiguration {
        get {
            if let configuration = storage[IMSequenceAllocationConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMSequenceAllocationConfiguration.load(from: environment)
            storage[IMSequenceAllocationConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMSequenceAllocationConfigurationStorageKey.self] = newValue }
    }

    var commandOwnerRoutingConfiguration: IMCommandOwnerRoutingConfiguration {
        get {
            if let configuration = storage[IMCommandOwnerRoutingConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMCommandOwnerRoutingConfiguration.load(from: environment)
            storage[IMCommandOwnerRoutingConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMCommandOwnerRoutingConfigurationStorageKey.self] = newValue }
    }

    var conversationMemberCacheConfiguration: IMConversationMemberCacheConfiguration {
        get {
            if let configuration = storage[IMConversationMemberCacheConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMConversationMemberCacheConfiguration.load(from: environment)
            storage[IMConversationMemberCacheConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMConversationMemberCacheConfigurationStorageKey.self] = newValue }
    }

    var messageWriteBatchConfiguration: IMMessageWriteBatchConfiguration {
        get {
            if let configuration = storage[IMMessageWriteBatchConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMMessageWriteBatchConfiguration.load(from: environment)
            storage[IMMessageWriteBatchConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMMessageWriteBatchConfigurationStorageKey.self] = newValue }
    }

    var sequenceBlockAllocator: IMSequenceBlockAllocator {
        get {
            if let allocator = storage[IMSequenceBlockAllocatorStorageKey.self] {
                return allocator
            }
            let allocator = IMSequenceBlockAllocator()
            storage[IMSequenceBlockAllocatorStorageKey.self] = allocator
            return allocator
        }
        set { storage[IMSequenceBlockAllocatorStorageKey.self] = newValue }
    }

    var messageWriteBatcher: IMMessageWriteBatcher {
        get {
            if let batcher = storage[IMMessageWriteBatcherStorageKey.self] {
                return batcher
            }
            let batcher = IMMessageWriteBatcher()
            storage[IMMessageWriteBatcherStorageKey.self] = batcher
            return batcher
        }
        set { storage[IMMessageWriteBatcherStorageKey.self] = newValue }
    }

    var conversationWriteCoordinator: IMConversationWriteCoordinator {
        get {
            if let coordinator = storage[IMConversationWriteCoordinatorStorageKey.self] {
                return coordinator
            }
            let coordinator = IMConversationWriteCoordinator()
            storage[IMConversationWriteCoordinatorStorageKey.self] = coordinator
            return coordinator
        }
        set { storage[IMConversationWriteCoordinatorStorageKey.self] = newValue }
    }

    var conversationMemberCache: IMConversationMemberCache {
        get {
            if let cache = storage[IMConversationMemberCacheStorageKey.self] {
                return cache
            }
            let cache = IMConversationMemberCache()
            storage[IMConversationMemberCacheStorageKey.self] = cache
            return cache
        }
        set { storage[IMConversationMemberCacheStorageKey.self] = newValue }
    }

    var directConversationPairCache: IMDirectConversationPairCache {
        get {
            if let cache = storage[IMDirectConversationPairCacheStorageKey.self] {
                return cache
            }
            let cache = IMDirectConversationPairCache()
            storage[IMDirectConversationPairCacheStorageKey.self] = cache
            return cache
        }
        set { storage[IMDirectConversationPairCacheStorageKey.self] = newValue }
    }

    var messageWriteMetrics: IMMessageWriteMetrics {
        get {
            if let metrics = storage[IMMessageWriteMetricsStorageKey.self] {
                return metrics
            }
            let metrics = IMMessageWriteMetrics()
            storage[IMMessageWriteMetricsStorageKey.self] = metrics
            return metrics
        }
        set { storage[IMMessageWriteMetricsStorageKey.self] = newValue }
    }
}
