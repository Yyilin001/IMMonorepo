import Foundation
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import Testing

@Suite("node-local shared policy facts", .timeLimit(.minutes(1)))
struct V2NodePolicyStateCacheTests {
    @Test("ten thousand hot sends reuse facts without another owner fetch")
    func hotSends() async throws {
        let cache = V2NodePolicyStateCache(), source = PolicyCacheSource()
        let user = UUID(), scopes: [V2PolicyAuthorizationScope] = [.account(user)]
        _ = try await cache.load(scopes: scopes, loader: source.read)
        for _ in 0..<10_000 {
            let cached = try await cache.cached(scopes: scopes)
            #expect(cached?.count == 1)
        }
        #expect(await source.reads == 1)
        await cache.shutdown()
    }

    @Test("committed policy invalidation reloads only its shared scope")
    func changedScope() async throws {
        let cache = V2NodePolicyStateCache(), source = PolicyCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        _ = try await cache.load(scopes: [first, second], loader: source.read)
        await source.disable()
        await cache.invalidate(first.key)
        #expect(try await cache.cached(scopes: [first]) == nil)
        #expect(try await cache.cached(scopes: [second])?.count == 1)
        let refreshed = try await cache.load(scopes: [first], loader: source.read)
        if case .account(let account) = refreshed[0].facts { #expect(!account.isActive) }
        else { Issue.record("expected account facts") }
        #expect(await source.reads == 2)
        await cache.shutdown()
    }

    @Test("invalidation fences an older in-flight response and its waiters")
    func staleColdResponse() async throws {
        let cache = V2NodePolicyStateCache(), source = PolicyCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let task = Task { try await cache.load(scopes: [scope], loader: source.read) }
        while await source.reads == 0 { await Task.yield() }
        await cache.invalidate(scope.key)
        await source.disable(); await source.release()
        await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await task.value }
        #expect(try await cache.cached(scopes: [scope]) == nil)
        let states = try await cache.load(scopes: [scope], loader: source.read)
        if case .account(let account) = states[0].facts { #expect(!account.isActive) }
        else { Issue.record("expected account facts") }
        await cache.shutdown()
    }

    @Test("one invalidated scope preserves unrelated facts sharing a cold RPC batch")
    func independentScopesInBatch() async throws {
        let cache = V2NodePolicyStateCache(), source = PolicyCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let mixed = Task { try await cache.load(scopes: [first, second], loader: source.read) }
        while await source.reads == 0 { await Task.yield() }
        let independent = Task { try await cache.load(scopes: [second], loader: source.read) }
        await cache.invalidate(first.key)
        await source.release()
        await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) { try await mixed.value }
        #expect(try await independent.value.count == 1)
        #expect(try await cache.cached(scopes: [second])?.count == 1)
        #expect(try await cache.cached(scopes: [first]) == nil)
        #expect(await source.reads == 1)
        await cache.shutdown()
    }

    @Test("concurrent first sends share one actual fetch")
    func coalescedLoad() async throws {
        let cache = V2NodePolicyStateCache(), source = PolicyCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let tasks = (0..<32).map { _ in Task { try await cache.load(scopes: [scope], loader: source.read) } }
        while await source.reads == 0 { await Task.yield() }
        await source.release()
        for task in tasks { #expect(try await task.value.count == 1) }
        #expect(await source.reads == 1)
        await cache.shutdown()
    }

    @Test("background renewal replaces authority before the next send")
    func backgroundRenewal() async throws {
        let cache = V2NodePolicyStateCache(), source = PolicyCacheSource()
        let scope = V2PolicyAuthorizationScope.account(UUID())
        await source.setLifetime(.seconds(5))
        let original = try await cache.load(scopes: [scope], loader: source.read)[0]
        await source.setLifetime(.seconds(30))
        await cache.refreshOnce(loader: source.read)
        let renewed = try #require(try await cache.cached(scopes: [scope])?.first)
        #expect(renewed.deadline > original.deadline)
        #expect(await source.refreshes == 1)
        #expect(await source.reads == 2)
        await cache.shutdown()
    }

    @Test("caller cancellation retains actual load capacity until its response settles")
    func actualLoadCapacity() async throws {
        let cache = V2NodePolicyStateCache(maximumLoads: 1), source = PolicyCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        await source.block()
        let task = Task { try await cache.load(scopes: [first], loader: source.read) }
        while await source.reads == 0 { await Task.yield() }
        task.cancel()
        await #expect(throws: V2PolicyAuthorizationLifecycleError.busy) {
            try await cache.load(scopes: [second], loader: source.read)
        }
        await source.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await cache.load(scopes: [second], loader: source.read).count == 1)
        await cache.shutdown()
    }

    @Test("bounded eviction reloads facts and expired facts are never a hot hit")
    func boundedAndExpired() async throws {
        let cache = V2NodePolicyStateCache(maximumEntries: 1), source = PolicyCacheSource()
        let first = V2PolicyAuthorizationScope.account(UUID()), second = V2PolicyAuthorizationScope.account(UUID())
        _ = try await cache.load(scopes: [first], loader: source.read)
        _ = try await cache.load(scopes: [second], loader: source.read)
        #expect(try await cache.cached(scopes: [first]) == nil)
        #expect(try await cache.cached(scopes: [second])?.count == 1)
        await cache.shutdown()
        let expiredCache = V2NodePolicyStateCache()
        await source.setLifetime(.milliseconds(100))
        _ = try await expiredCache.load(scopes: [first], loader: source.read)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await expiredCache.cached(scopes: [first]) == nil)
        await source.setLifetime(.seconds(-1))
        await #expect(throws: V2PolicyAuthorizationLifecycleError.invalidTarget) {
            try await expiredCache.load(scopes: [first], loader: source.read)
        }
        #expect(try await expiredCache.cached(scopes: [first]) == nil)
        await expiredCache.shutdown()
    }
}

private actor PolicyCacheSource {
    private(set) var reads = 0
    private(set) var refreshes = 0
    private var active = true
    private var lifetime = Duration.seconds(30)
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    func disable() { active = false }
    func setLifetime(_ value: Duration) { lifetime = value }
    func block() { blocked = true }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
    func read(_ scopes: [V2PolicyAuthorizationScope], _ refresh: Bool) async throws -> [V2PolicyOwnerState] {
        reads += 1; if refresh { refreshes += 1 }
        let captured = active, deadline = ContinuousClock.now + lifetime
        if blocked { await withCheckedContinuation { waiter = $0 } }
        return scopes.map { scope in
            guard case .account(let user) = scope else { preconditionFailure("test account scope") }
            return .init(owner: .init(scope: scope, ownerID: UUID(), epoch: 1, revision: captured ? 1 : 2,
                validUntil: Date().addingTimeInterval(30)),
                facts: .account(.init(userID: user, isActive: captured, specialKind: nil, specialStatus: nil,
                    allowsServiceMessages: nil, allowsCustomerMessages: nil)), deadline: deadline)
        }
    }
}
