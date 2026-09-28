import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

/// 消息搜索状态存储。
///
/// 它独立于会话列表渲染地持有防抖搜索状态；代次栅栏确保较慢的陈旧结果
/// 无法在主线程上覆盖更新的查询或筛选选择。
@MainActor
@Observable
final class V2ConversationSearchStore {
    /// 搜索状态。
    enum State: Equatable {
        case idle
        case indexing
        case loading
        case loaded
        case failed
    }

    enum PaginationFailure: Equatable { case unavailable, invalidContinuation }
    private(set) var paginationFailure: PaginationFailure?

    private let searcher: any V2ConversationMessageSearching
    private let progressReader: (any V2ConversationMessageSearchProgressReading)?
    private let scope: V2MessageSearchScope
    private let actorUserID: UserID?
    private(set) var senderContextGeneration: UInt64 = 0
    private var senderFilterRoomID: RoomID?
    private var generation = 0
    private var paginationOperation: UUID?
    var isLoadingMore: Bool { paginationOperation != nil }
    private var loadedRequest: V2MessageSearchRequest?
    private var cursor: V2MessageSearchCursor?

    var query = ""
    var contentFilter: V2MessageSearchContentFilter = .all
    private(set) var senderFilter: UserID?
    private(set) var senderPresentationKey: V2ProfileViewLookupKey?
    private(set) var hits: [V2MessageSearchHit] = []
    private(set) var state: State = .idle
    private(set) var canLoadMore = false
    private(set) var isCatchingUp = false

    init(searcher: any V2ConversationMessageSearching, scope: V2MessageSearchScope = .allMessages, actorUserID: UserID? = nil) {
        self.searcher = searcher
        progressReader = searcher as? any V2ConversationMessageSearchProgressReading
        self.scope = scope
        self.actorUserID = actorUserID
    }

    func search() async {
        generation &+= 1
        let requestGeneration = generation
        paginationOperation = nil
        paginationFailure = nil
        loadedRequest = nil
        cursor = nil
        canLoadMore = false
        hits = []
        isCatchingUp = false
        guard !query.isEmpty || contentFilter != .all else {
            state = .idle
            canLoadMore = false
            return
        }
        state = .loading
        let request = V2MessageSearchRequest(query: query, scope: scope, contentFilter: contentFilter, senderUserID: senderFilter)
        do {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            let page = try await searcher.searchMessages(request)
            try Task.checkCancellation()
            guard isCurrent(request, generation: requestGeneration) else { return }
            var catchingUp = false
            if let progressReader {
                let progress = try? await progressReader.messageSearchIndexProgress()
                try Task.checkCancellation()
                guard isCurrent(request, generation: requestGeneration) else { return }
                catchingUp = progress?.isCatchingUp ?? false
            }
            var seen = Set<MessageID>()
            hits = page.hits.filter { seen.insert($0.messageID).inserted }
            cursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            isCatchingUp = catchingUp
            loadedRequest = request
            state = .loaded
        } catch is CancellationError {
            return
        } catch V2MessageSearchError.indexUnavailable(.building) {
            guard isCurrent(request, generation: requestGeneration) else { return }
            canLoadMore = false
            state = .indexing
        } catch {
            guard isCurrent(request, generation: requestGeneration) else { return }
            canLoadMore = false
            state = .failed
        }
    }

    func loadMore() async {
        guard let cursor, let loadedRequest, state == .loaded, paginationOperation == nil,
              isCurrent(loadedRequest, generation: generation) else { return }
        let operation = UUID()
        paginationOperation = operation
        paginationFailure = nil
        defer { if paginationOperation == operation { paginationOperation = nil } }
        let requestGeneration = generation
        let request = V2MessageSearchRequest(query: query, scope: scope, contentFilter: contentFilter, senderUserID: senderFilter, cursor: cursor)
        do {
            let page = try await searcher.searchMessages(request)
            try Task.checkCancellation()
            guard isCurrent(request, generation: requestGeneration) else { return }
            guard page.nextCursor != cursor else {
                // Deduplicating hits cannot make a stalled continuation
                // progress. Stop before committing this inconsistent page.
                self.cursor = nil
                canLoadMore = false
                paginationFailure = .invalidContinuation
                return
            }
            var catchingUp = false
            if let progressReader {
                let progress = try? await progressReader.messageSearchIndexProgress()
                try Task.checkCancellation()
                guard isCurrent(request, generation: requestGeneration) else { return }
                catchingUp = progress?.isCatchingUp ?? false
            }
            var seen = Set(hits.map(\.messageID))
            hits.append(contentsOf: page.hits.filter { seen.insert($0.messageID).inserted })
            self.cursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            isCatchingUp = catchingUp
        } catch is CancellationError {
            return
        } catch V2MessageSearchError.indexUnavailable(.building) {
            guard isCurrent(request, generation: requestGeneration) else { return }
            canLoadMore = false
            state = .indexing
        } catch V2MessageSearchError.indexUnavailable {
            guard !Task.isCancelled, isCurrent(request, generation: requestGeneration) else { return }
            canLoadMore = false
            state = .failed
        } catch V2MessageSearchError.cursorDoesNotMatchScope {
            guard !Task.isCancelled, isCurrent(request, generation: requestGeneration) else { return }
            self.cursor = nil
            canLoadMore = false
            paginationFailure = .invalidContinuation
        } catch {
            guard !Task.isCancelled, isCurrent(request, generation: requestGeneration) else { return }
            // Keep the confirmed page and its cursor. Retrying pagination must
            // not replace useful local results with a full-screen error.
            paginationFailure = .unavailable
        }
    }

    private func isCurrent(_ request: V2MessageSearchRequest, generation: Int) -> Bool {
        generation == self.generation && query == request.query && contentFilter == request.contentFilter && senderFilter == request.senderUserID
    }

    /// 观察搜索索引状态。
    ///
    /// 该观察任务由视图持有。初始的已就绪取值很重要：
    /// 索引重建可能在一次失败查询与流注册之间完成，只有先读取当前快照才能避免错判。
    func observeIndexState() async {
        guard let progressReader else { return }
        var previous: V2MessageSearchIndexSnapshot?
        do {
            for try await snapshot in await progressReader.messageSearchIndexUpdates() {
                guard !Task.isCancelled else { return }
                guard snapshot != previous else { continue }
                previous = snapshot
                guard !query.isEmpty || contentFilter != .all else { continue }
                switch snapshot.state {
                case .ready:
                    await search()
                case .building, .failed:
                    generation &+= 1
                    paginationOperation = nil
                    loadedRequest = nil
                    cursor = nil
                    canLoadMore = false
                    state = snapshot.state == .building ? .indexing : .failed
                }
            }
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { state = .failed } }
    }

    func refreshSenderPresentationContext() async {
        guard let userID = senderFilter, let room = senderFilterRoomID else { return }
        let generation = senderContextGeneration
        let context = try? await searcher.searchConversationContext(roomID: room)
        guard !Task.isCancelled, generation == senderContextGeneration,
              senderFilter == userID, senderFilterRoomID == room else { return }
        senderPresentationKey = context?.authorKey(for: userID, in: room, actorUserID: actorUserID)
    }

    func filterToSender(_ userID: UserID, in originRoom: RoomID? = nil) {
        let room: RoomID? = if case .room(let room) = scope { room } else { originRoom }
        guard senderFilter != userID || senderFilterRoomID != room else { return }
        senderContextGeneration &+= 1
        senderFilter = userID
        senderFilterRoomID = room
        senderPresentationKey = nil
    }

    func clearSenderFilter() {
        guard senderFilter != nil else { return }
        senderContextGeneration &+= 1
        senderFilter = nil
        senderFilterRoomID = nil
        senderPresentationKey = nil
    }
}
