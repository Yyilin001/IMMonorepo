import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing
@testable import IMApp

@MainActor
@Suite("V2 search continuation ownership", .timeLimit(.minutes(1)))
struct V2ConversationSearchConcurrencyTests {
    @Test("重复加载只发一页并按消息 ID 去重")
    func paginationIsSingleFlightAndDeduplicated() async throws {
        let first = hit("first"), second = hit("second")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "query"
        await store.search()
        let load = Task { await store.loadMore() }
        await client.waitForPage()
        #expect(store.isLoadingMore)
        for _ in 0..<19 { await store.loadMore() }
        #expect(await client.pageCalls == 1)
        await client.finishPage(.init(hits: [first, second, second], nextCursor: nil))
        await load.value
        #expect(store.hits.map(\.messageID) == [first.messageID, second.messageID])
        #expect(!store.canLoadMore)
        #expect(!store.isLoadingMore)
    }

    @Test("新搜索开始后旧分页不能追加结果或修改当前加载状态")
    func oldPageCannotPublishIntoNewQuery() async throws {
        let first = hit("first"), old = hit("old page")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "query"
        await store.search()
        let load = Task { await store.loadMore() }
        await client.waitForPage()
        store.query = "new query"
        await store.search()
        await client.finishPage(.init(hits: [old], nextCursor: nil))
        await load.value
        #expect(store.hits.map(\.messageID) == [first.messageID])
        #expect(store.canLoadMore)
        #expect(store.state == .loaded)
    }

    @Test("筛选成员读公开名称，未知成员不读 UUID")
    func senderFilterUsesPublicDisplayName() async throws {
        let client = SearchPageBarrier(first: hit("first"))
        let store = V2ConversationSearchStore(searcher: client)
        let known = UserID(uuid: UUID()), unknown = UserID(uuid: UUID())
        await client.setName("公开名称", for: known)
        store.filterToSender(known)
        await store.refreshSenderDisplayName()
        #expect(store.senderFilterDisplayName == "公开名称")
        store.filterToSender(unknown)
        #expect(store.senderFilterDisplayName == "选定成员")
        await store.refreshSenderDisplayName()
        #expect(store.senderFilterDisplayName == "选定成员")
        store.clearSenderFilter()
        #expect(store.senderFilter == nil)
    }

    @Test("索引 ready 自动重查，也接收订阅前已完成的初值", arguments: [false, true])
    func indexCompletionRefreshesCurrentQuery(completesBeforeObservation: Bool) async throws {
        let expected = hit("indexed result")
        let client = IndexStateSearchClient(hit: expected)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "indexed"
        await store.search()
        #expect(store.state == .indexing)
        if completesBeforeObservation { await client.makeReady() }
        let observer = Task { await store.observeIndexState() }
        await client.waitForSubscription()
        if !completesBeforeObservation { await client.makeReady() }
        await client.finishUpdates()
        await observer.value
        #expect(store.state == .loaded)
        #expect(store.hits.map(\.messageID) == [expected.messageID])
    }

    @Test("重复游标停止分页，不发布该页，也不再发相同请求")
    func stalledCursorStopsPagination() async throws {
        let first = hit("first"), inconsistent = hit("inconsistent page")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "query"
        await store.search()
        let loading = Task { await store.loadMore() }
        await client.waitForPage()
        let original = V2MessageSearchCursor(storage: .global(createdAt: first.createdAt, messageID: first.messageID), filterFingerprint: "query")
        await client.finishPage(.init(hits: [inconsistent], nextCursor: original))
        await loading.value
        #expect(store.state == .failed)
        #expect(!store.canLoadMore && !store.isLoadingMore)
        #expect(store.hits == [first])
        await store.loadMore()
        #expect(await client.pageCalls == 1)
    }

    @Test("取消分页不提交迟到结果，并释放本页以允许再次加载")
    func cancelledPageCanBeRetried() async throws {
        let first = hit("first"), second = hit("second")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "query"
        await store.search()
        let cancelled = Task { await store.loadMore() }
        await client.waitForPage()
        cancelled.cancel()
        await client.finishPage(.init(hits: [second], nextCursor: nil))
        await cancelled.value
        #expect(store.hits == [first])
        #expect(store.state == .loaded && store.canLoadMore && !store.isLoadingMore)
        let retry = Task { await store.loadMore() }
        await client.waitForPage()
        await client.finishPage(.init(hits: [second], nextCursor: nil))
        await retry.value
        #expect(store.hits == [first, second])
        #expect(await client.pageCalls == 2)
    }

    @Test("分页失败释放运行状态，重新搜索后可以继续", arguments: [false, true])
    func failedPageCanRestart(indexRebuilding: Bool) async throws {
        let first = hit("first")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "query"
        await store.search()
        let loading = Task { await store.loadMore() }
        await client.waitForPage()
        await client.failPage(indexRebuilding ? V2MessageSearchError.indexUnavailable(.building) : V2MessageSearchError.cursorDoesNotMatchScope)
        await loading.value
        #expect(store.state == (indexRebuilding ? .indexing : .failed))
        #expect(!store.isLoadingMore && !store.canLoadMore)
        #expect(store.hits == [first])
        await store.search()
        #expect(store.state == .loaded && store.canLoadMore)
        let retry = Task { await store.loadMore() }
        await client.waitForPage()
        await client.finishPage(.init(hits: [], nextCursor: nil))
        await retry.value
        #expect(!store.isLoadingMore && !store.canLoadMore)
    }

    @Test("旧查询的索引进度迟到不能改变新查询", arguments: [false, true])
    func lateProgressCannotChangeNewQuery(fromPagination: Bool) async throws {
        let first = hit("first"), old = hit("old")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "old query"
        if fromPagination { await store.search() }
        await client.pauseNextProgress()
        let oldWork = Task {
            if fromPagination { await store.loadMore() } else { await store.search() }
        }
        if fromPagination {
            await client.waitForPage()
            await client.finishPage(.init(hits: [old], nextCursor: nil))
        }
        await client.waitForProgress()
        #expect(store.hits == (fromPagination ? [first] : []))
        store.query = "new query"
        await store.search()
        #expect(store.state == .loaded && !store.isLoadingMore)
        await client.finishProgress(.init(state: .ready, pendingJobCount: 10))
        await oldWork.value
        #expect(store.hits == [first])
        #expect(store.state == .loaded && store.canLoadMore && !store.isCatchingUp)
    }

    @Test("筛选变化后旧页不能进入新搜索", arguments: [false, true])
    func stalePageCannotChangeNewFilter(sender: Bool) async throws {
        let first = hit("first")
        let client = SearchPageBarrier(first: first)
        let store = V2ConversationSearchStore(searcher: client)
        store.query = "query"
        await store.search()
        let loading = Task { await store.loadMore() }
        await client.waitForPage()
        if sender { store.filterToSender(.init(uuid: UUID())) } else { store.contentFilter = .image }
        await store.search()
        await client.finishPage(.init(hits: [hit("stale filter")], nextCursor: nil))
        await loading.value
        #expect(store.hits == [first])
        #expect(store.state == .loaded && store.canLoadMore && !store.isLoadingMore)
    }

    private func hit(_ text: String) -> V2MessageSearchHit {
        .init(messageID: .init(uuid: UUID()), roomID: .init(uuid: UUID()), roomSequence: 1,
              senderUserID: .init(uuid: UUID()), text: text, createdAt: Date())
    }
}

private actor SearchPageBarrier: V2ConversationMessageSearching, V2ConversationMessageSearchProgressReading {
    private let first: V2MessageSearchHit
    private var continuation: CheckedContinuation<V2MessageSearchPage, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var pageCalls = 0
    private var names: [UserID: String] = [:]
    private var shouldPauseProgress = false
    private var progressContinuation: CheckedContinuation<V2MessageSearchIndexProgress, Never>?
    private var progressWaiter: CheckedContinuation<Void, Never>?
    init(first: V2MessageSearchHit) { self.first = first }
    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        guard request.cursor != nil else {
            let cursor = V2MessageSearchCursor(storage: .global(createdAt: first.createdAt, messageID: first.messageID), filterFingerprint: request.query)
            return .init(hits: [first], nextCursor: cursor)
        }
        pageCalls += 1
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }
    func waitForPage() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishPage(_ page: V2MessageSearchPage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
    func failPage(_ error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
    func pauseNextProgress() { shouldPauseProgress = true }
    func messageSearchIndexProgress() async throws -> V2MessageSearchIndexProgress {
        guard shouldPauseProgress else { return .init(state: .ready, pendingJobCount: 0) }
        shouldPauseProgress = false
        return await withCheckedContinuation {
            progressContinuation = $0
            progressWaiter?.resume()
            progressWaiter = nil
        }
    }
    func waitForProgress() async {
        guard progressContinuation == nil else { return }
        await withCheckedContinuation { progressWaiter = $0 }
    }
    func finishProgress(_ progress: V2MessageSearchIndexProgress) {
        progressContinuation?.resume(returning: progress)
        progressContinuation = nil
    }
    func messageSearchIndexUpdates() async -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func setName(_ name: String, for userID: UserID) { names[userID] = name }
    func searchSenderDisplayName(userID: UserID) async throws -> String? { names[userID] }
}

private actor IndexStateSearchClient: V2ConversationMessageSearching, V2ConversationMessageSearchProgressReading {
    private let hit: V2MessageSearchHit
    private var ready = false
    private var continuation: AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error>.Continuation?
    private var subscriptionWaiter: CheckedContinuation<Void, Never>?
    init(hit: V2MessageSearchHit) { self.hit = hit }
    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        guard ready else { throw V2MessageSearchError.indexUnavailable(.building) }
        return .init(hits: [hit], nextCursor: nil)
    }
    func messageSearchIndexProgress() async throws -> V2MessageSearchIndexProgress {
        .init(state: ready ? .ready : .building, pendingJobCount: 0)
    }
    func messageSearchIndexUpdates() async -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
            $0.yield(.init(state: ready ? .ready : .building, generation: 1, indexVersion: 1))
            subscriptionWaiter?.resume()
            subscriptionWaiter = nil
        }
    }
    func waitForSubscription() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { subscriptionWaiter = $0 }
    }
    func makeReady() {
        ready = true
        continuation?.yield(.init(state: .ready, generation: 1, indexVersion: 1))
    }
    func finishUpdates() { continuation?.finish() }
}
