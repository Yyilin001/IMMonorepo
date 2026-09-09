import Foundation
import SwiftUI
import UIKit
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp
import Testing

@MainActor
@Suite("Conversation window production integration", .serialized, .timeLimit(.minutes(1)))
struct V2ConversationWindowTests {
    @Test("deep pagination, head insertions and deletion keep a bounded production window")
    func productionWindowLifecycle() async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-app-window-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...2_000)
        let source = V2GRDBConversationDataSource(localStore: local)
        let store = V2ConversationListStore(environment: .init(userID: "user", projections: .init(dataSource: source)))
        await store.refresh()
        #expect(store.items.count == 50)
        for _ in 0..<25 {
            show(try #require(store.items.last?.id), in: store)
            await store.loadMoreConversations()
            #expect(store.items.count <= 300)
            consumeRestoration(in: store)
        }
        #expect(store.items.count == 300 && store.hasEarlierConversations)
        let anchor = store.items[100]
        show(anchor.id, in: store)
        try await seed(local, range: 2_001...4_000)
        await store.refresh()
        #expect(store.items.count == 300 && store.hasEarlierConversations)
        #expect(store.viewport.restoration?.itemID == anchor.id)
        #expect(store.items[50].id == anchor.id)
        consumeRestoration(in: store)
        let removal = try V2ClientSyncRecord(sequence: 4_001, sourceEventID: .init(UUID().uuidString), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
            "room_id": anchor.id, "is_pinned": false, "is_archived": true, "mute_until_ms": 0, "updated_at_ms": 1_750_010_000_000
        ]))
        _ = try await local.apply(.init(generation: 1, records: [removal], nextSyncToken: .init("removed"), receipt: .init("removed-receipt"), hasMore: false, capabilityProfile: "base"))
        await store.refresh()
        #expect(!store.items.contains { $0.id == anchor.id })
        let fallback = try #require(store.viewport.restoration?.itemID)
        #expect(store.items.contains { $0.id == fallback })
        consumeRestoration(in: store)
        let beforeEarlier = try #require(store.items.first?.lastActivity)
        await store.loadEarlierConversations()
        #expect(store.items.count == 300)
        #expect(try #require(store.items.first?.lastActivity) > beforeEarlier)
        #expect(store.viewport.restoration?.itemID == store.items.first?.id)
        await store.refresh(resetWindow: true)
        #expect(store.items.count == 50 && !store.hasEarlierConversations)
        #expect(store.items.first?.id == Self.identifier(4_000))
        #expect(store.viewport.anchorID == nil && store.viewport.restoration == nil)
        try await local.close()
    }

    @Test("scrolling during SQLite refresh uses the latest visible row", arguments: [0, 250])
    func scrollingDuringRead(newIndex: Int) async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-scroll-read-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...1_000)
        let gate = V2ListWindowReadGate()
        let source = V2GatedConversationWindows(source: .init(localStore: local), gate: gate)
        let store = V2ConversationListStore(environment: .init(userID: "user", projections: .init(dataSource: source)))
        await store.refresh()
        for _ in 0..<7 { await store.loadMoreConversations(); consumeRestoration(in: store) }
        let latest = store.items[newIndex].id
        show(store.items[200].id, in: store)
        await gate.arm()
        let refresh = Task { await store.refresh() }
        await gate.waitForRead()
        show(latest, in: store)
        await gate.release()
        await refresh.value
        #expect(store.viewport.restoration?.itemID == latest)
        #expect(store.items.contains { $0.id == latest })
        #expect(store.items.count == 300)
        #expect(await gate.reads == (newIndex == 0 ? 2 : 1))
        try await local.close()
    }

    enum PageScrollCase: Sendable { case next, earlierInside, earlierOutside }

    @Test("paging cannot evict a newer visible row", arguments: [PageScrollCase.next, .earlierInside, .earlierOutside])
    func scrollingDuringPagination(scenario: PageScrollCase) async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-page-scroll-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...1_000)
        let gate = V2ListWindowReadGate()
        let source = V2GatedConversationWindows(source: .init(localStore: local), gate: gate)
        let store = V2ConversationListStore(environment: .init(userID: "user", projections: .init(dataSource: source)))
        await store.refresh()
        for _ in 0..<7 { await store.loadMoreConversations(); consumeRestoration(in: store) }
        let before = store.items.map(\.id), cursor = store.conversationNextCursor
        show(scenario == .next ? before[299] : before[0], in: store)
        await gate.arm()
        let page = Task {
            if scenario == .next { await store.loadMoreConversations() }
            else { await store.loadEarlierConversations() }
        }
        await gate.waitForRead()
        let latest = scenario == .next ? before[0] : before[scenario == .earlierInside ? 20 : 299]
        show(latest, in: store)
        await gate.release()
        await page.value
        #expect(store.viewport.anchorID == latest)
        #expect(store.items.count == 300)
        if scenario == .earlierInside {
            #expect(store.items.map(\.id) != before)
            #expect(store.viewport.restoration?.itemID == latest)
        } else {
            #expect(store.items.map(\.id) == before)
            #expect(store.conversationNextCursor == cursor)
            #expect(store.viewport.restoration == nil)
            show(scenario == .next ? before[299] : before[0], in: store)
            if scenario == .next { await store.loadMoreConversations() }
            else { await store.loadEarlierConversations() }
            #expect(store.items.map(\.id) != before)
        }
        try await local.close()
    }

    @Test("viewport uses intersecting geometry, not prefetched row appearance")
    func viewportGeometryAndRestorationIdentity() throws {
        let viewport = V2ListViewport()
        viewport.reconcile(ids: ["before", "top", "next", "prefetched"])
        viewport.resize(height: 200)
        viewport.record(id: "prefetched", position: .init(minY: 400, maxY: 450))
        #expect(viewport.anchorID == nil)
        viewport.record(id: "next", position: .init(minY: 30, maxY: 80))
        viewport.record(id: "top", position: .init(minY: -20, maxY: 30))
        viewport.record(id: "before", position: .init(minY: -70, maxY: -20))
        #expect(viewport.anchorID == "top")
        viewport.restore(to: "next")
        let old = try #require(viewport.restoration)
        viewport.restore(to: "next")
        #expect(viewport.restoration?.id == old.id)
        viewport.restore(to: "top")
        viewport.didRequestRestoration(old)
        #expect(viewport.restoration?.itemID == "top")
        viewport.didRequestRestoration(try #require(viewport.restoration))
        viewport.record(id: "top", position: .init(minY: -50, maxY: 0))
        #expect(viewport.anchorID == "next")
        viewport.reconcile(ids: ["top"])
        viewport.record(id: "next", position: .init(minY: 0, maxY: 50))
        #expect(viewport.anchorID == nil)
    }

    @Test("a disappearing old row cannot erase its replacement or override user scrolling")
    func rowOwnershipAndUserScroll() async throws {
        let viewport = V2ListViewport()
        viewport.reconcile(ids: ["row"])
        viewport.resize(height: 200)
        let old = UUID(), current = UUID()
        viewport.record(id: "row", position: .init(minY: 0, maxY: 50), ownerID: old)
        viewport.record(id: "row", position: .init(minY: 10, maxY: 60), ownerID: current)
        viewport.remove(id: "row", ownerID: old)
        #expect(viewport.containsVisibleRow("row"))
        viewport.restore(to: "row")
        let request = try #require(viewport.restoration)
        var scrollCalls = 0
        await viewport.performRestoration(request) { _ in
            scrollCalls += 1
            viewport.userDidBeginScrolling()
        }
        #expect(scrollCalls == 1 && viewport.restoration == nil)
        viewport.remove(id: "row", ownerID: current)
        #expect(!viewport.containsVisibleRow("row"))
    }

    @Test("the actual SwiftUI List reports visible rows and restores the anchor after refresh")
    func actualListGeometryAndScrollRestoration() async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-app-list-layout-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...1_000)
        let source = V2GRDBConversationDataSource(localStore: local)
        let store = V2ConversationListStore(environment: .init(userID: "user", projections: .init(dataSource: source)))
        await store.refresh()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: V2ConversationListView(store: store))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        host.view.layoutIfNeeded()
        try await waitUntil { store.viewport.anchorID.map(store.viewport.containsVisibleRow) == true }
        for _ in 0..<7 {
            let last = try #require(store.items.last?.id)
            store.viewport.restore(to: last)
            do { try await waitUntil { store.viewport.restoration == nil && store.viewport.containsVisibleRow(last) } }
            catch {
                Issue.record("scroll target=\(last), anchor=\(String(describing: store.viewport.anchorID)), pending=\(String(describing: store.viewport.restoration)), count=\(store.items.count), contains=\(store.items.contains { $0.id == last }), layout=\(store.viewport.layoutDescription(for: last))")
                throw error
            }
            await store.loadMoreConversations()
            try await waitUntil { store.viewport.restoration == nil }
        }
        #expect(store.items.count == 300 && store.hasEarlierConversations)
        try await seed(local, range: 1_001...2_000)
        let anchor = try #require(store.viewport.anchorID)
        #expect(store.viewport.containsVisibleRow(anchor))
        await store.refresh()
        do { try await waitUntil { store.viewport.restoration == nil && store.viewport.containsVisibleRow(anchor) } }
        catch {
            Issue.record("refresh target=\(anchor), anchor=\(String(describing: store.viewport.anchorID)), pending=\(String(describing: store.viewport.restoration)), layout=\(store.viewport.layoutDescription(for: anchor))")
            throw error
        }
        #expect(store.items.contains { $0.id == anchor })
        #expect(store.items.count == 300)
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
        try await local.close()
    }

    private enum LayoutWaitError: Error { case timedOut(line: Int) }
    private func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LayoutWaitError.timedOut(line: line)
    }

    private func show(_ id: String, in store: V2ConversationListStore) {
        store.viewport.reset()
        store.viewport.reconcile(ids: store.items.map(\.id))
        store.viewport.resize(height: 600)
        store.viewport.record(id: id, position: .init(minY: 0, maxY: 60))
    }

    private func consumeRestoration(in store: V2ConversationListStore) {
        if let request = store.viewport.restoration { store.viewport.didRequestRestoration(request) }
    }

    private func seed(_ store: GRDBV2LocalSyncStore, range: ClosedRange<Int>) async throws {
        for start in stride(from: range.lowerBound, through: range.upperBound, by: 100) {
            let end = min(start + 99, range.upperBound)
            let records = try (start...end).map { value in
                try V2ClientSyncRecord(sequence: UInt64(value), sourceEventID: .init(UUID().uuidString), projectionKind: "room", payload: JSONSerialization.data(withJSONObject: [
                    "event_type": "room.created", "room_id": Self.identifier(value), "title": "Room \(value)",
                    "owner_user_id": Self.identifier(99_999), "membership_revision": 1,
                    "delivery_mode": "standard_fanout", "created_at_ms": 1_750_000_000_000 + value * 1_000
                ]))
            }
            _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("seed-\(end)"), receipt: .init("seed-receipt-\(end)"), hasMore: false, capabilityProfile: "base"))
        }
    }

    nonisolated private static func identifier(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }
}
