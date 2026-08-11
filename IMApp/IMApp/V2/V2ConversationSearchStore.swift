import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

/// Owns debounced message-search state independently from conversation list
/// rendering. Generation fencing prevents a slower stale result from replacing
/// the newer query or filter selection on the main actor.
@MainActor
@Observable
final class V2ConversationSearchStore {
    enum State: Equatable {
        case idle
        case indexing
        case loading
        case loaded
        case failed
    }

    private let searcher: any V2ConversationMessageSearching
    private let progressReader: (any V2ConversationMessageSearchProgressReading)?
    private let scope: V2MessageSearchScope
    private var generation = 0
    private var cursor: V2MessageSearchCursor?

    var query = ""
    var contentFilter: V2MessageSearchContentFilter = .all
    private(set) var senderFilter: UserID?
    private(set) var hits: [V2MessageSearchHit] = []
    private(set) var state: State = .idle
    private(set) var canLoadMore = false
    private(set) var isCatchingUp = false

    init(searcher: any V2ConversationMessageSearching, scope: V2MessageSearchScope = .allMessages) {
        self.searcher = searcher
        progressReader = searcher as? any V2ConversationMessageSearchProgressReading
        self.scope = scope
    }

    func search() async {
        generation &+= 1
        let requestGeneration = generation
        cursor = nil
        hits = []
        isCatchingUp = false
        guard !query.isEmpty || contentFilter != .all else {
            state = .idle
            canLoadMore = false
            return
        }
        state = .loading
        do {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            let page = try await searcher.searchMessages(.init(query: query, scope: scope, contentFilter: contentFilter, senderUserID: senderFilter))
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            hits = page.hits
            cursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            if let progressReader {
                let progress = try? await progressReader.messageSearchIndexProgress()
                isCatchingUp = progress?.isCatchingUp ?? false
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch V2MessageSearchError.indexUnavailable(.building) {
            guard requestGeneration == generation else { return }
            state = .indexing
        } catch {
            guard requestGeneration == generation else { return }
            state = .failed
        }
    }

    func loadMore() async {
        guard let cursor, state == .loaded else { return }
        let requestGeneration = generation
        do {
            let page = try await searcher.searchMessages(
                .init(query: query, scope: scope, contentFilter: contentFilter, senderUserID: senderFilter, cursor: cursor)
            )
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            hits += page.hits
            self.cursor = page.nextCursor
            canLoadMore = page.nextCursor != nil
            if let progressReader {
                let progress = try? await progressReader.messageSearchIndexProgress()
                isCatchingUp = progress?.isCatchingUp ?? false
            }
        } catch is CancellationError {
            return
        } catch V2MessageSearchError.indexUnavailable(.building) {
            guard requestGeneration == generation else { return }
            state = .indexing
        } catch {
            guard requestGeneration == generation else { return }
            state = .failed
        }
    }

    func filterToSender(_ userID: UserID) {
        guard senderFilter != userID else { return }
        senderFilter = userID
    }

    func clearSenderFilter() {
        guard senderFilter != nil else { return }
        senderFilter = nil
    }
}
