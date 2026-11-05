import Testing
@testable import ConversationListKit

@Suite("RankedViewportEngine")
struct RankedViewportEngineTests {
    private struct Fact: Sendable {
        let id: Int
        let group: Int
        let activity: Int
    }

    @Test
    func structuralReplacementSortsInsideActorAndRejectsOlderGeneration() async {
        let engine = RankedViewportEngine<Int>()
        let facts = [
            Fact(id: 1, group: 1, activity: 10),
            Fact(id: 2, group: 0, activity: 20),
            Fact(id: 3, group: 0, activity: 10)
        ]

        let replacement = await engine.replace(
            with: facts,
            generation: 2,
            key: \.id,
            areInIncreasingOrder: { lhs, rhs in
                if lhs.group != rhs.group { return lhs.group < rhs.group }
                return lhs.activity > rhs.activity
            }
        )
        #expect(replacement.accepted)
        #expect(replacement.orderedKeys == [2, 3, 1])

        let stale = await engine.replace(with: [99], generation: 1)
        #expect(!stale)
        let entries = await engine.entries(in: 0 ..< 3)
        #expect(entries.map(\.key) == [2, 3, 1])
    }

    @Test
    func frameAppliesAllMovesBeforeReadingViewport() async {
        let engine = RankedViewportEngine<Int>()
        await engine.replace(with: [0, 1, 2, 3])
        let result = await engine.applyFrame(
            moves: [.init(key: 3, position: 0), .init(key: 2, position: 0)],
            reading: [0 ..< 3]
        )

        #expect(result.accepted)
        #expect(result.entries.map(\.key) == [2, 3, 0])
    }
}
