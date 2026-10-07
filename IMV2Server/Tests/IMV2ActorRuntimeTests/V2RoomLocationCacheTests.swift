import Testing
@testable import IMV2ActorRuntime

@Suite("Exact room location cache order")
struct V2RoomLocationCacheTests {
    @Test("reads preserve oldest eviction and the configured capacity")
    func readsDoNotReorderEviction() {
        var cache = V2RoomLocationCache<String, Int>(maximumCount: 2)
        cache.remember(1, for: "a")
        cache.remember(2, for: "b")
        #expect(cache["a"] == 1)
        cache.remember(3, for: "c")
        #expect(cache.count == 2)
        #expect(cache["a"] == nil)
        #expect(cache["b"] == 2 && cache["c"] == 3)
    }

    @Test("remember replaces one node and moves that room to newest")
    func rememberRefreshesExactRoomOrder() {
        var cache = V2RoomLocationCache<String, Int>(maximumCount: 2)
        cache.remember(1, for: "a")
        cache.remember(2, for: "b")
        cache.remember(3, for: "a")
        cache.remember(4, for: "a")
        #expect(cache.count == 2)
        cache.remember(5, for: "c")
        #expect(cache.count == 2)
        #expect(cache["b"] == nil)
        #expect(cache["a"] == 4 && cache["c"] == 5)
    }

    @Test("exact removal and reinsert maintain middle, head and tail links")
    func removalAndReinsertPreserveEviction() {
        var cache = V2RoomLocationCache<String, Int>(maximumCount: 3)
        cache.remember(1, for: "a")
        cache.remember(2, for: "b")
        cache.remember(3, for: "c")
        #expect(cache.removeValue(forKey: "b") == 2)
        #expect(cache.removeValue(forKey: "b") == nil)
        cache.remember(20, for: "b")
        cache.remember(4, for: "d")
        #expect(cache["a"] == nil)
        #expect(cache["b"] == 20 && cache["c"] == 3 && cache["d"] == 4)
        #expect(cache.removeValue(forKey: "c") == 3) // oldest
        #expect(cache.removeValue(forKey: "d") == 4) // newest
        #expect(cache.removeValue(forKey: "b") == 20) // final node
        #expect(cache.count == 0)
        cache.remember(5, for: "e")
        cache.remember(6, for: "f")
        cache.removeAll()
        cache.remember(7, for: "g")
        #expect(cache.count == 1 && cache["g"] == 7)
        #expect(cache["e"] == nil && cache["f"] == nil)
    }
}
