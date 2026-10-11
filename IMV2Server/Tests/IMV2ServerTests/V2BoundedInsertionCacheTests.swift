import Testing
@testable import IMV2ServerInfrastructure

@Suite("Bounded result cache insertion order")
struct V2BoundedInsertionCacheTests {
    @Test func replacementDoesNotRefreshAndCapacityOne() {
        var cache = V2BoundedInsertionCache<Int, Int>(capacity: 2)
        cache.insert(10, for: 1); cache.insert(20, for: 2)
        cache.insert(11, for: 1); cache.insert(30, for: 3)
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 2) == 20 && cache.value(for: 3) == 30)
        #expect(cache.count == 2)
        var single = V2BoundedInsertionCache<Int, Int>(capacity: 1)
        single.insert(10, for: 1); single.insert(11, for: 1)
        #expect(single.value(for: 1) == 11)
        single.insert(20, for: 2)
        #expect(single.value(for: 1) == nil && single.count == 1)
    }
    @Test func repeatedWrapsMatchFIFOReference() {
        var cache = V2BoundedInsertionCache<Int, Int>(capacity: 7)
        var order: [Int] = [], reference: [Int: Int] = [:]
        for value in 0..<1000 {
            let key = (value * 3) % 11
            if reference[key] == nil { order.append(key) }
            reference[key] = value
            if order.count > 7 { reference.removeValue(forKey: order.removeFirst()) }
            cache.insert(value, for: key)
            #expect(cache.count == reference.count)
            for candidate in 0..<11 { #expect(cache.value(for: candidate) == reference[candidate]) }
        }
    }
}
