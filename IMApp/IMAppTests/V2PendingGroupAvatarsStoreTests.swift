import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Account pending group avatars page lifecycle", .timeLimit(.minutes(1)))
struct V2PendingGroupAvatarsStoreTests {
    @Test func paginationReplacesThePageAndAnEmptiedLaterPageReturnsToFirst() async throws {
        let first = try page(count: 32, hasNext: true), second = try page(count: 4)
        let reader = PendingAvatarReader(pages: [first, second, .init(entries: [], next: nil), first])
        let store = makeStore(reader)
        await store.observe(); await loaded(store)
        #expect(store.page?.entries.count == 32 && store.isFirstPage)
        store.nextPage(); await loaded(store)
        #expect(store.page?.entries == second.entries && !store.isFirstPage)
        store.refreshCurrentPage(); await loaded(store)
        #expect(store.page?.entries == first.entries && store.isFirstPage)
        let cursors = await reader.cursors
        #expect(cursors.count == 4 && cursors[0] == nil && cursors[1] == first.next && cursors[2] == first.next && cursors[3] == nil)
        await store.close()
    }

    @Test func aCancelledNonCooperativeReadKeepsItsSlotAcrossReopen() async throws {
        let gate = PendingAvatarGate(), old = try page(count: 1), current = try page(count: 2)
        let reader = PendingAvatarReader(pages: [old, current], firstGate: gate)
        let store = makeStore(reader)
        await store.observe(); await gate.entered()
        store.suspend()
        #expect(store.page == nil)
        await store.observe()
        for _ in 0..<100 { store.refresh() }
        #expect(await reader.cursors.count == 1)
        await gate.release(); await loaded(store)
        #expect(store.page?.entries == current.entries)
        #expect(await reader.cursors.count == 2)
        #expect(await reader.maximumActive == 1)
        await store.close()
        #expect(store.page == nil)
    }

    @Test func closingDrainsAndRejectsLateAccountData() async throws {
        let gate = PendingAvatarGate(), reader = PendingAvatarReader(pages: [try page(count: 1)], firstGate: gate)
        let store = makeStore(reader)
        await store.observe(); await gate.entered()
        store.suspend()
        let closing = Task { await store.close() }
        await gate.release(); await closing.value
        guard case .inactive = store.state else { Issue.record("late account journal data was displayed"); return }
        #expect(await reader.active == 0)
        store.refresh()
        await store.observe()
        #expect(await reader.cursors.count == 1)
    }

    @Test func repeatedInvalidationsDoNotStarveCompletedResultsForTheSamePage() async throws {
        let firstGate = PendingAvatarGate(), secondGate = PendingAvatarGate()
        let first = try page(count: 1), second = try page(count: 2)
        let reader = PendingAvatarReader(pages: [first, second], firstGate: firstGate, secondGate: secondGate)
        let store = makeStore(reader)
        await store.observe(); await firstGate.entered()
        for _ in 0..<100 { store.refreshCurrentPage() }
        await firstGate.release(); await secondGate.entered()
        #expect(store.page?.entries == first.entries)
        await secondGate.release()
        while store.page?.entries != second.entries { await Task.yield() }
        #expect(await reader.cursors.count == 2)
        await store.close()
    }

    @Test func onlyJournalNotificationsRefreshTheListAndFailuresCanBeRetried() async throws {
        let first = try page(count: 1), second = try page(count: 2)
        let reader = PendingAvatarReader(pages: [first, second]), notifier = V2ProjectionChangeNotifier()
        let store = makeStore(reader, notifier: notifier)
        let observing = Task { await store.observe() }
        await loaded(store)
        await notifier.publish(.init(scopes: .presentations, requiresImmediateRefresh: true))
        for _ in 0..<20 { await Task.yield() }
        #expect(await reader.cursors.count == 1)
        await reader.failNext()
        await notifier.publish(.init(scopes: .conversationDetails, requiresImmediateRefresh: true))
        while true {
            if case .failed = store.state { break }
            await Task.yield()
        }
        store.refresh(); await loaded(store)
        #expect(store.page?.entries == second.entries)
        observing.cancel(); store.suspend(); await observing.value; await store.close(); await notifier.finish()
    }

    private func makeStore(_ reader: PendingAvatarReader, notifier: V2ProjectionChangeNotifier? = nil) -> V2PendingGroupAvatarsStore {
        .init(reader: reader, notifier: notifier) { _, _ in preconditionFailure("This test does not open a management sheet") }
    }
    private func loaded(_ store: V2PendingGroupAvatarsStore) async {
        while store.page == nil { await Task.yield() }
    }
    private func page(count: Int, hasNext: Bool = false) throws -> V2PendingGroupAvatarPage {
        let actor = UserID(uuid: UUID()), now = Date()
        let entries = try (0..<count).map { _ -> V2PendingGroupAvatarPage.Entry in
            let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: .init(uuid: UUID()), expectedRevision: 0, mutation: .remove)
            let intent = V2GroupAvatarIntent(actorUserID: actor, command: command, uploadJobID: nil, stage: .submitted,
                submissionStarted: true, recoveryAction: nil, closedDisposition: .awaitingDecision,
                attempts: 1, retryAt: now, issue: .outcomeUnknown, receipt: nil, closureProof: nil)
            return .init(intent: intent, createdAt: now)
        }
        let next = hasNext ? entries.last.map { V2PendingGroupAvatarPage.Cursor(actorUserID: actor, createdAt: now.timeIntervalSince1970, operationID: $0.id) } : nil
        return .init(entries: entries, next: next)
    }
}

private actor PendingAvatarReader: V2PendingGroupAvatarReading {
    let pages: [V2PendingGroupAvatarPage], firstGate: PendingAvatarGate?, secondGate: PendingAvatarGate?
    private(set) var cursors: [V2PendingGroupAvatarPage.Cursor?] = []
    private(set) var active = 0, maximumActive = 0
    private var nextIndex = 0, shouldFail = false
    init(pages: [V2PendingGroupAvatarPage], firstGate: PendingAvatarGate? = nil, secondGate: PendingAvatarGate? = nil) {
        self.pages = pages; self.firstGate = firstGate; self.secondGate = secondGate
    }
    func failNext() { shouldFail = true }
    func pendingPage(after: V2PendingGroupAvatarPage.Cursor?) async throws -> V2PendingGroupAvatarPage {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        cursors.append(after)
        if shouldFail { shouldFail = false; throw V2GroupAvatarIntentError.invalidRecord }
        let value = pages[min(nextIndex, pages.count - 1)]; nextIndex += 1
        if cursors.count == 1 { await firstGate?.wait() }
        else if cursors.count == 2 { await secondGate?.wait() }
        return value
    }
}

private actor PendingAvatarGate {
    private let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) } }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}
