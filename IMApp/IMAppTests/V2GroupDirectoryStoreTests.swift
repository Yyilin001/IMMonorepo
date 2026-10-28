import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2GroupDirectoryStoreTests {
    @Test func paginationRefreshAndSearchUseIndependentLocalDirectory() async throws {
        let source = DirectoryReader()
        let store = V2GroupDirectoryStore(reader: source)
        await store.refresh()
        #expect(store.items.count == 50)
        #expect(store.nextCursor != nil)
        await store.loadMore()
        #expect(store.items.count == 75)
        #expect(store.nextCursor == nil)
        await store.refresh()
        #expect(store.items.count == 75)
        #expect(Set(store.items.map(\.id)).count == 75)
        store.query = "群组 074"
        await store.refresh()
        #expect(store.items.map(\.title) == ["群组 074"])
        store.query = "不存在"
        await store.refresh()
        #expect(store.state == .loaded)
        #expect(store.items.isEmpty)
        store.query = ""
        await store.refresh()
        #expect(store.items.count == 50)
    }

    @Test func lateSearchResultCannotOverwriteNewerSearch() async {
        let source = DelayedDirectoryReader()
        let store = V2GroupDirectoryStore(reader: source)
        store.query = "old"
        let previous = Task { await store.refresh() }
        await source.waitForOldRead()
        store.query = "new"
        await store.refresh()
        await source.releaseOldRead()
        await previous.value
        #expect(store.items.map(\.title) == ["new"])
    }

    @Test func projectionNotificationsRefreshVisibleDirectory() async throws {
        let source = DirectoryReader()
        let notifier = V2ProjectionChangeNotifier()
        let store = V2GroupDirectoryStore(reader: source, notifier: notifier)
        let observation = Task { await store.observe() }
        defer { observation.cancel() }
        for _ in 0..<200 {
            if store.items.count == 50 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.items.count == 50)
        await source.setEmpty()
        await notifier.publish(.init(scopes: .conversations, requiresImmediateRefresh: true))
        for _ in 0..<200 {
            if store.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.items.isEmpty)
        #expect(store.state == .loaded)
        observation.cancel()
        await observation.value
    }

    @Test func transientReadFailureKeepsPreviouslyLoadedGroupsAndCanRetry() async {
        let source = DirectoryReader()
        let store = V2GroupDirectoryStore(reader: source)
        await store.refresh()
        await source.setFailing(true)
        await store.refresh()
        #expect(store.state == .loaded)
        #expect(store.items.count == 50)
        #expect(store.feedback != nil)
        await store.loadMore()
        #expect(store.items.count == 50)
        #expect(!store.isLoadingMore)
        await source.setFailing(false)
        await store.loadMore()
        #expect(store.items.count == 75)
        #expect(store.feedback == nil)
    }

    @Test func initialFailureIsExplicitAndSearchDoesNotKeepUnrelatedResults() async {
        let source = DirectoryReader()
        await source.setFailing(true)
        let store = V2GroupDirectoryStore(reader: source)
        await store.refresh()
        #expect(store.state == .failed)
        await source.setFailing(false)
        await store.refresh()
        #expect(store.state == .loaded)
        await source.setFailing(true)
        store.query = "新搜索"
        await store.refresh()
        #expect(store.items.isEmpty)
        #expect(store.state == .failed)
    }
}

private actor DirectoryReader: V2GroupDirectoryReading {
    private var failing = false
    private var empty = false
    func setEmpty() { empty = true }
    func setFailing(_ value: Bool) { failing = value }
    func groupDirectoryPage(matching query: String, after cursor: V2ClientGroupDirectoryCursor?, limit: Int) async throws -> V2ClientGroupDirectoryPage {
        if failing { throw Failure.read }
        if empty { return .init(items: [], nextCursor: nil) }
        let all = try (0..<75).map { index in
            try V2ClientGroupDirectoryItem(roomID: .init("directory-\(index)"), title: String(format: "群组 %03d", index), isArchived: index == 0)
        }.filter { query.isEmpty || $0.title.contains(query) }
        let remaining = all.filter { cursor == nil || $0.title > cursor!.title }
        let items = Array(remaining.prefix(limit))
        let next = remaining.count > limit ? items.last.map { V2ClientGroupDirectoryCursor(title: $0.title, roomID: $0.roomID) } : nil
        return .init(items: items, nextCursor: next)
    }
    enum Failure: Error { case read }
}

private actor DelayedDirectoryReader: V2GroupDirectoryReading {
    private var pending: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitForOldRead() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func releaseOldRead() { pending?.resume(); pending = nil }
    func groupDirectoryPage(matching query: String, after cursor: V2ClientGroupDirectoryCursor?, limit: Int) async throws -> V2ClientGroupDirectoryPage {
        if query == "old" {
            await withCheckedContinuation { continuation in
                pending = continuation; started = true; waiter?.resume(); waiter = nil
            }
        }
        return try .init(items: [.init(roomID: .init("directory-" + query), title: query, isArchived: false)], nextCursor: nil)
    }
}
