import Foundation
import Synchronization
import IMV2ActorContracts
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import Testing

@Suite("versioned memory policy snapshots", .timeLimit(.minutes(1)))
struct V2PolicyFactsSnapshotCacheTests {
    @Test("room-sized capacity retains a working set larger than the former fixed node threshold")
    func roomSizedWorkingSet() async throws {
        let capacity = try V2NodePolicyStateCache.capacityForActiveRooms(7_000)
        let evictions = Mutex(0), source = SnapshotCacheSource()
        let cache = V2NodePolicyStateCache(maximumEntries: capacity, observe: { event in
            if case .capacityEviction = event { evictions.withLock { $0 += 1 } }
        })
        let scopes = (0..<35_000).map { _ in V2PolicyAuthorizationScope.account(UUID()) }
        for offset in stride(from: 0, to: scopes.count, by: 4) {
            _ = try await cache.loadSnapshots(scopes: Array(scopes[offset..<min(offset + 4, scopes.count)]), loader: source.read)
        }
        let reads = await source.reads
        #expect(try await cache.cachedSnapshots(scopes: Array(scopes.prefix(4)))?.count == 4)
        #expect(try await cache.cachedSnapshots(scopes: Array(scopes.suffix(4)))?.count == 4)
        #expect(await source.reads == reads)
        #expect(evictions.withLock { $0 } == 0)
        await cache.shutdown()
    }

    @Test("invalid and overflowing room capacities cannot create unbounded policy retention")
    func invalidRoomCapacity() {
        #expect(throws: V2ActorContractError.self) { try V2NodePolicyStateCache.capacityForActiveRooms(0) }
        #expect(throws: V2ActorContractError.self) { try V2NodePolicyStateCache.capacityForActiveRooms(Int.max) }
    }

    @Test("capacity eviction is counted independently of cold reads, updates and explicit invalidation")
    func capacityEvictionObservation() async throws {
        let evictions = Mutex(0), source = SnapshotCacheSource()
        let cache = V2NodePolicyStateCache(maximumEntries: 1, observe: { event in
            if case .capacityEviction = event { evictions.withLock { $0 += 1 } }
        })
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        _ = try await cache.loadSnapshots(scopes: [first], loader: source.read)
        try await cache.install(source.snapshot(first, version: 2, active: false))
        #expect(evictions.withLock { $0 } == 0)
        _ = try await cache.loadSnapshots(scopes: [second], loader: source.read)
        #expect(evictions.withLock { $0 } == 1)
        await cache.invalidate(second)
        _ = try await cache.loadSnapshots(scopes: [first], loader: source.read)
        #expect(evictions.withLock { $0 } == 1)
        await cache.shutdown()
    }

    @Test("a shared cold loader keeps its initiating send trace across the detached boundary")
    func coldLoaderTrace() async throws {
        let cache = V2NodePolicyStateCache(), source = SnapshotCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let trace = V2SendPathTrace(operations: [UUID().uuidString], segment: "room_actor")
        let loaded = try await V2SendPathTrace.$current.withValue(trace) {
            try await cache.loadSnapshots(scopes: [scope]) { scopes in
                #expect(V2SendPathTrace.current === trace)
                return try await source.read(scopes)
            }
        }
        #expect(loaded.count == 1)
        #expect(V2SendPathTrace.current == nil)
        await cache.shutdown()
    }

    @Test("ten thousand reads and a pushed policy update make no additional fetch")
    func hotReadsAndPush() async throws {
        let cache = V2NodePolicyStateCache(), source = SnapshotCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        _ = try await cache.loadSnapshots(scopes: [scope], loader: source.read)
        try await cache.install(source.snapshot(scope, version: 2, active: false), interestedOnly: true)
        for _ in 0..<10_000 {
            let value = try #require(try await cache.cachedSnapshots(scopes: [scope])?.first)
            #expect(value.version == 2)
            if case .account(let facts) = value.facts { #expect(!facts.isActive) }
        }
        #expect(await source.reads == 1)
        await cache.shutdown()
    }
    @Test("same-scope first readers share a load and cancellation does not abandon it")
    func sharedLoad() async throws {
        let cache = V2NodePolicyStateCache(), source = SnapshotCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let cancelled = Task { try await cache.loadSnapshots(scopes: [scope], loader: source.read) }
        while await source.reads == 0 { await Task.yield() }
        let others = (0..<32).map { _ in Task { try await cache.loadSnapshots(scopes: [scope], loader: source.read) } }
        cancelled.cancel(); await source.release()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        for task in others { #expect(try await task.value[0].version == 1) }
        #expect(await source.reads == 1)
        await cache.shutdown()
    }
    @Test("new push wins an older initializing RPC, including after LRU eviction")
    func initializationRace() async throws {
        let cache = V2NodePolicyStateCache(maximumEntries: 1), source = SnapshotCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let loading = Task { try await cache.loadSnapshots(scopes: [first], loader: source.read) }
        while await source.reads == 0 { await Task.yield() }
        try await cache.install(source.snapshot(first, version: 3, active: false), interestedOnly: true)
        try await cache.install(source.snapshot(second, version: 1, active: true))
        await source.release()
        #expect(try await loading.value[0].version == 3)
        #expect(try await cache.cachedSnapshots(scopes: [first])?.first?.version == 3)
        await cache.shutdown()
    }
    @Test("different cold scopes have no logical concurrency quota")
    func independentScopes() async throws {
        let cache = V2NodePolicyStateCache(), source = SnapshotCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let cold = Task { try await cache.loadSnapshots(scopes: [first], loader: source.read) }
        while await source.reads == 0 { await Task.yield() }
        let secondResult = try await cache.loadSnapshots(scopes: [second]) { scopes in
            try scopes.map { try source.snapshot($0, version: 1, active: true) }
        }
        #expect(secondResult.count == 1)
        await source.release(); _ = try await cold.value
        await cache.shutdown()
    }
    @Test("duplicate and older pushes cannot replace a newer snapshot")
    func orderedUpdates() async throws {
        let cache = V2NodePolicyStateCache(), source = SnapshotCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        let newest = try source.snapshot(scope, version: 5, active: false)
        try await cache.install(newest)
        try await cache.install(newest)
        try await cache.install(source.snapshot(scope, version: 4, active: true))
        #expect(try await cache.cachedSnapshots(scopes: [scope])?.first == newest)
        await #expect(throws: V2PolicyAuthorizationLifecycleError.corruptPersistence) {
            try await cache.install(source.snapshot(scope, version: 5, active: true))
        }
        await cache.shutdown()
    }
    @Test("the two directions of a pair represent the same versioned snapshot")
    func canonicalPair() async throws {
        let first = UUID(), second = UUID(), cache = V2NodePolicyStateCache()
        let forward = try V2PolicyFactsSnapshot(scope: .pair(first, second), version: 2, facts: .pair(.init(blocked: false, isFriend: true)))
        let reverse = try V2PolicyFactsSnapshot(scope: .pair(second, first), version: 2, facts: .pair(.init(blocked: false, isFriend: true)))
        #expect(forward == reverse)
        try await cache.install(forward); try await cache.install(reverse)
        #expect(try await cache.cachedSnapshots(scopes: [.pair(second, first)]) == [forward])
        await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidRequest) {
            try await cache.cachedSnapshots(scopes: [.pair(first, second), .pair(second, first)])
        }
        await cache.shutdown()
    }
    @Test("hot touches and installs preserve strict LRU eviction")
    func recentlyUsedEviction() async throws {
        let cache = V2NodePolicyStateCache(maximumEntries: 2), source = SnapshotCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID())
        let second = V2PolicyAuthorizationScope.account(UUID())
        let third = V2PolicyAuthorizationScope.account(UUID())
        for scope in [first, second] { _ = try await cache.loadSnapshots(scopes: [scope], loader: source.read) }
        for _ in 0..<10 { #expect(try await cache.cachedSnapshots(scopes: [first]) != nil) }
        try await cache.install(source.snapshot(third, version: 1, active: true))
        #expect(try await cache.cachedSnapshots(scopes: [second]) == nil)
        #expect(try await cache.cachedSnapshots(scopes: [third]) != nil)
        try await cache.install(source.snapshot(first, version: 2, active: false))
        try await cache.install(source.snapshot(second, version: 1, active: true))
        #expect(try await cache.cachedSnapshots(scopes: [third]) == nil)
        #expect(try await cache.cachedSnapshots(scopes: [first])?.first?.version == 2)
        await cache.shutdown()
    }
    @Test("eviction causes initialization, time does not")
    func eviction() async throws {
        let cache = V2NodePolicyStateCache(maximumEntries: 1), source = SnapshotCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        _ = try await cache.loadSnapshots(scopes: [first], loader: source.read)
        _ = try await cache.loadSnapshots(scopes: [second], loader: source.read)
        #expect(try await cache.cachedSnapshots(scopes: [first]) == nil)
        _ = try await cache.loadSnapshots(scopes: [first], loader: source.read)
        #expect(await source.reads == 3)
        await cache.shutdown()
    }
}
private actor SnapshotCacheSource {
    private(set) var reads = 0
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    func block() { blocked = true }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
    nonisolated func snapshot(_ scope: V2PolicyAuthorizationScope, version: Int64, active: Bool) throws -> V2PolicyFactsSnapshot {
        guard case .account(let user) = scope else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        return try .init(scope: scope, version: version, facts: .account(.init(userID: user, isActive: active,
            specialKind: nil, specialStatus: nil, allowsServiceMessages: nil, allowsCustomerMessages: nil)))
    }
    func read(_ scopes: [V2PolicyAuthorizationScope]) async throws -> [V2PolicyFactsSnapshot] {
        reads += 1
        let captured = try scopes.map { try snapshot($0, version: 1, active: true) }
        if blocked { await withCheckedContinuation { waiter = $0 } }
        return captured
    }
}
