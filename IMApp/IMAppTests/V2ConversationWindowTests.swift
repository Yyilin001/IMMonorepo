import ConversationListKit
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
    @Test("full loading, head insertions and deletion preserve the visible conversation")
    func productionWindowLifecycle() async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-app-window-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...2_000)
        let source = V2GRDBConversationDataSource(localStore: local, requestLatestVisible: { _ in })
        let store = V2ConversationListStore(environment: .init(userID: "user", projections: .init(dataSource: source)))
        await store.refresh()
        #expect(store.items.count == 2_000)
        let anchor = store.items[100]
        show(anchor.id, in: store)
        try await seed(local, range: 2_001...4_000)
        await store.refresh()
        #expect(store.items.count == 4_000)
        #expect(store.viewport.restoration?.itemID == anchor.id)
        #expect(store.items.contains { $0.id == anchor.id })
        consumeRestoration(in: store)
        let removal = try V2ClientSyncRecord(sequence: 4_001, sourceEventID: .init(UUID().uuidString), projectionKind: "conversation_state", payload: JSONSerialization.data(withJSONObject: [
            "room_id": anchor.id, "is_pinned": false, "is_archived": true, "mute_until_ms": 0, "updated_at_ms": 1_750_010_000_000, "revision": 1
        ]))
        _ = try await local.apply(.init(generation: 1, records: [removal], nextSyncToken: .init("removed"), receipt: .init("removed-receipt"), hasMore: false, capabilityProfile: "base"))
        await store.refresh()
        #expect(!store.items.contains { $0.id == anchor.id })
        let fallback = try #require(store.viewport.restoration?.itemID)
        #expect(store.items.contains { $0.id == fallback })
        consumeRestoration(in: store)
        await store.refresh(resetWindow: true)
        #expect(store.items.count == 3_999)
        #expect(store.items.first?.id == Self.identifier(4_000))
        #expect(store.viewport.anchorID == nil && store.viewport.restoration == nil)
        try await local.close()
    }

    @Test("scrolling during SQLite refresh uses the latest visible row", arguments: [0, 250])
    func scrollingDuringRead(newIndex: Int) async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-scroll-read-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...1_000)
        let gate = V2ListWindowReadGate()
        let source = V2GatedConversationWindows(source: .init(localStore: local, requestLatestVisible: { _ in }), gate: gate)
        let store = V2ConversationListStore(environment: .init(userID: "user", projections: .init(dataSource: source)))
        await store.refresh()
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
        #expect(store.items.count == 1_000)
        #expect(await gate.reads == 1)
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

    @Test("the production snapshot list reports visible rows and restores the anchor after refresh")
    func actualListGeometryAndScrollRestoration() async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-app-list-layout-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        try await seed(local, range: 1...1_000)
        let source = V2GRDBConversationDataSource(localStore: local, requestLatestVisible: { _ in })
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
        let last = try #require(store.items.last?.id)
        store.viewport.restore(to: last)
        try await waitUntil { store.viewport.restoration == nil && store.viewport.containsVisibleRow(last) }
        #expect(store.items.count == 1_000)
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
        #expect(store.items.count == 2_000)
        window.isHidden = true
        window.rootViewController = nil
        await Task.yield()
        try await local.close()
    }

    enum ListFeed { case orderedWindow, rankedEvents }
    private struct ProbeRow: Identifiable, Equatable, Sendable {
        let id: Int
        var value: Int
    }

    @Test("a frame reconfigures only the changed visible slot in a 10,000-row list",
          arguments: [ListFeed.orderedWindow, .rankedEvents])
    func coalescedVisibleSlotUpdates(feed: ListFeed) async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var configured = [Int]()
        var firstVisible: Int?
        let configuration = FixedPositionListController<ProbeRow>.Configuration(configure: { cell, row in
            configured.append(row.value)
            var content = cell.defaultContentConfiguration()
            content.text = String(row.value)
            cell.contentConfiguration = content
        }, visibleRowsChanged: { rows, _ in firstVisible = rows.first?.row.value })
        var rows = (0..<10_000).map { ProbeRow(id: $0, value: $0) }
        let ordered = OrderedListWindow(rows)
        let ranked = RankedListViewport<ProbeRow>()
        let source: any FixedPositionViewportDataSource<ProbeRow>
        switch feed {
        case .orderedWindow: source = ordered
        case .rankedEvents:
            let engine = RankedViewportEngine<Int>()
            await engine.replace(with: rows.map(\.id))
            ranked.install(engine: engine, totalCount: rows.count, pinnedCount: 0, rows: rows)
            source = ranked
        }
        let controller = FixedPositionListController(source: source, configuration: configuration)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; controller.stop(); previousWindow?.makeKey() }
        try await waitUntil { firstVisible == 0 }
        let list = try #require(controller.view as? UICollectionView)
        let path = IndexPath(item: 0, section: 0)
        let originalCell = try #require(list.cellForItem(at: path))
        configured.removeAll()
        switch feed {
        case .orderedWindow:
            rows[0].value = -1
            ordered.replace(with: rows)
            rows[0].value = -2
            rows[9_999].value = -3
            ordered.replace(with: rows)
        case .rankedEvents:
            ranked.enqueueRealtimeUpdate(.init(id: 0, value: -1), targetPosition: nil)
            ranked.enqueueRealtimeUpdate(.init(id: 0, value: -2), targetPosition: nil)
            ranked.enqueueRealtimeUpdate(.init(id: 9_999, value: -3), targetPosition: nil)
            #expect(ranked.row(at: 9_999) == nil)
        }
        try await waitUntil { firstVisible == -2 }
        #expect(configured == [-2])
        #expect(list.cellForItem(at: path) === originalCell)
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
                    "capacity_class": "standard",
                    "created_at_ms": 1_750_000_000_000 + value * 1_000
                ]))
            }
            _ = try await store.apply(.init(generation: 1, records: records, nextSyncToken: .init("seed-\(end)"), receipt: .init("seed-receipt-\(end)"), hasMore: false, capabilityProfile: "base"))
        }
    }

    nonisolated private static func identifier(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }
}
