import Testing
import ConversationListKit

@MainActor
struct RankedListViewportTests {
    private struct Row: Identifiable, Equatable, Sendable {
        let id: Int
        var revision = 0
    }

    @Test func swipeIdentityLookupTracksMovesAndRejectsMissingOrAmbiguousOwners() {
        let window = OrderedListWindow([Row(id: 1), Row(id: 2)])
        #expect(window.row(withID: 1) == Row(id: 1))
        window.replace(with: [Row(id: 2), Row(id: 1, revision: 1)])
        #expect(window.row(withID: 1) == Row(id: 1, revision: 1))
        window.replace(with: [Row(id: 2), Row(id: 2, revision: 1)])
        #expect(window.row(withID: 1) == nil)
        #expect(window.row(withID: 2) == nil)
    }

    @Test func framePreservesMoveWhenLaterPayloadHasNoPosition() async {
        let rows = (0..<100).map { Row(id: $0) }
        let viewport = RankedListViewport<Row>()
        let engine = RankedViewportEngine<Int>()
        await engine.replace(with: rows.map(\.id))
        viewport.install(engine: engine, totalCount: rows.count, pinnedCount: 0, rows: rows)
        viewport.enqueueRealtimeUpdate(Row(id: 90, revision: 1), targetPosition: 0)
        viewport.enqueueRealtimeUpdate(Row(id: 90, revision: 2), targetPosition: nil)
        viewport.commitFrame(in: [-10 ..< -2, 0..<3, 200..<210])
        await waitForBinding { viewport.row(at: 0) == Row(id: 90, revision: 2) }
        #expect(viewport.row(at: 1)?.id == 0)
        #expect(viewport.row(at: 3) == nil)
    }

    @Test(arguments: [true, false])
    func structuralChangeFollowsQueuedAndInflightMoves(startedFrame: Bool) async {
        let rows = (0..<5).map { Row(id: $0) }
        let viewport = RankedListViewport<Row>()
        let engine = RankedViewportEngine<Int>()
        await engine.replace(with: rows.map(\.id))
        viewport.install(engine: engine, totalCount: rows.count, pinnedCount: 0, rows: rows)
        viewport.enqueueRealtimeUpdate(Row(id: 4, revision: 1), targetPosition: 0)
        if startedFrame { viewport.commitFrame(in: [0..<3]) }
        let mutation = await viewport.applyStructuralChange(removing: [1], inserting: [.init(row: Row(id: 5), position: 1)])
        #expect(mutation?.currentCount == 5)
        viewport.commitFrame(in: [0..<3])
        await waitForBinding { viewport.row(at: 1)?.id == 5 }
        #expect(viewport.row(at: 0) == Row(id: 4, revision: 1))
        #expect(!viewport.hasCompleteRowCache(containing: 1))
    }

    @Test func rebuildingReplaysInflightMoveAndLatestPayloadTogether() async {
        let viewport = RankedListViewport<Row>()
        let engine = RankedViewportEngine<Int>()
        await engine.replace(with: [1, 2])
        viewport.install(engine: engine, totalCount: 2, pinnedCount: 0, rows: [Row(id: 1), Row(id: 2)])
        viewport.enqueueRealtimeUpdate(Row(id: 2, revision: 1), targetPosition: 0)
        viewport.commitFrame(in: [0..<2])
        viewport.enqueueRealtimeUpdate(Row(id: 2, revision: 2), targetPosition: nil)
        let replay = viewport.takeRealtimeUpdatesForStructuralRebuild()
        #expect(replay.count == 1)
        #expect(replay.first?.row == Row(id: 2, revision: 2))
        #expect(replay.first?.targetPosition == 0)
    }

    @Test func replacingViewportDiscardsOldFrameResponse() async {
        let viewport = RankedListViewport<Row>()
        let old = RankedViewportEngine<Int>()
        let new = RankedViewportEngine<Int>()
        await old.replace(with: [1])
        await new.replace(with: [2])
        viewport.install(engine: old, totalCount: 1, pinnedCount: 0, rows: [Row(id: 1)])
        viewport.commitFrame(in: [0..<1])
        viewport.install(engine: new, totalCount: 1, pinnedCount: 0, rows: [Row(id: 2)])
        viewport.commitFrame(in: [0..<1])
        await waitForBinding { viewport.row(at: 0)?.id == 2 }
        #expect(!viewport.hasCompleteRowCache(containing: 1))
    }

    private func waitForBinding(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), .now < deadline { await Task.yield() }
        #expect(condition())
    }
}
