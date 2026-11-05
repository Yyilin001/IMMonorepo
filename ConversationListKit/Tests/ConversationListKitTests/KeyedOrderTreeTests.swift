import Testing
@testable import ConversationListKit

@Suite("KeyedOrderTree")
struct KeyedOrderTreeTests {
    @Test
    func movesExposeCorrectRanksAndVisibleSlice() {
        let index = KeyedOrderTree<Int, Int>()
        index.rebuild(Array(0 ..< 10), key: { $0 })

        #expect(index.moveToFront(forKey: 7))
        #expect(index.moveToFront(forKey: 3))
        #expect(index.position(ofKey: 3) == 0)
        #expect(index.position(ofKey: 7) == 1)
        #expect(index.element(at: 2) == 0)

        let slice = index.elements(in: 0 ..< 5)
        #expect(slice.map(\.position) == [0, 1, 2, 3, 4])
        #expect(slice.map(\.element) == [3, 7, 0, 1, 2])
    }

    @Test
    func replacementAndRemovalDoNotCorruptTheRankIndex() {
        let index = KeyedOrderTree<Int, String>()
        index.rebuild(["one", "two", "three"], key: key(for:))

        #expect(index.replaceElement("TWO", forKey: 2))
        #expect(index.removeElement(forKey: 1) == "one")
        #expect(index.count == 2)
        #expect(index.element(at: 0) == "TWO")
        #expect(index.element(at: 1) == "three")
        #expect(index.position(ofKey: 3) == 1)
        #expect(index.position(ofKey: 1) == nil)
    }

    @Test
    func boundedSliceClampsWithoutTraversingTheWholeIndex() {
        let index = KeyedOrderTree<Int, Int>()
        index.rebuild(Array(0 ..< 1_000), key: { $0 })

        let slice = index.elements(in: 990 ..< 1_100)
        #expect(slice.count == 10)
        #expect(slice.first?.position == 990)
        #expect(slice.first?.element == 990)
        #expect(slice.last?.position == 999)
        #expect(slice.last?.element == 999)
    }

    @Test
    func repeatedMovesPreserveEveryRankAgainstAnArrayOracle() {
        let index = KeyedOrderTree<Int, Int>()
        var expected = Array(0 ..< 200)
        index.rebuild(expected, key: { $0 })

        for step in 0 ..< 1_000 {
            let value = (step &* 37 + 11) % expected.count
            #expect(index.moveToFront(forKey: value))
            expected.removeAll { $0 == value }
            expected.insert(value, at: 0)

            if step.isMultiple(of: 25) {
                let slice = index.elements(in: 0 ..< expected.count)
                #expect(slice.map(\.element) == expected)
                for (rank, value) in expected.enumerated() {
                    #expect(index.position(ofKey: value) == rank)
                }
            }
        }
    }

    @Test
    func moveToAnArbitraryRankPreservesTheRequestedFinalPosition() {
        let index = KeyedOrderTree<Int, Int>()
        index.rebuild(Array(0 ..< 6), key: { $0 })

        #expect(index.move(forKey: 1, to: 4))
        #expect(index.elements(in: 0 ..< 6).map(\.element) == [0, 2, 3, 4, 1, 5])
        #expect(index.move(forKey: 5, to: 0))
        #expect(index.elements(in: 0 ..< 6).map(\.element) == [5, 0, 2, 3, 4, 1])
    }

    @Test
    func structuralInsertAndRemoveKeepTheTreeConsistent() {
        let index = KeyedOrderTree<Int, Int>()
        index.rebuild([1, 2, 3], key: { $0 })

        index.insertAtFront(4, forKey: 4)
        #expect(index.removeElement(forKey: 2) == 2)
        #expect(index.elements(in: 0 ..< index.count).map(\.element) == [4, 1, 3])
        #expect(index.position(ofKey: 4) == 0)
        #expect(index.position(ofKey: 3) == 2)
        #expect(!index.contains(2))
    }

    private func key(for value: String) -> Int {
        switch value {
        case "one": 1
        case "two": 2
        case "three": 3
        default: fatalError("Unexpected fixture")
        }
    }
}
