@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Control housekeeping category budget")
struct V2ControlHousekeepingBudgetTests {
    @Test(arguments: [1, 2, 3, 9, 10, 11, 1_024, Int.max - 1, Int.max])
    func boundedAndFairAcrossCategoryRotation(limit: Int) {
        var served = Set<Int>()
        for rotation in 0..<10 {
            var budget = ControlHousekeepingDeletionBudget(total: limit, categoryCount: 10, rotation: UInt(rotation))
            var remaining = limit
            for category in 0..<10 {
                let value = budget.take()
                #expect(value >= 0 && value <= remaining)
                remaining -= value
                if value > 0 { served.insert(category) }
            }
            #expect(remaining == 0)
            #expect(budget.take() == 0)
        }
        #expect(served == Set(0..<10))
    }

    @Test(arguments: [1, 2, 10, Int.max])
    func maximumRotationAndSingleCategory(categoryCount: Int) {
        var budget = ControlHousekeepingDeletionBudget(total: Int.max, categoryCount: categoryCount, rotation: UInt.max)
        // A single category must safely receive Int.max; very large category
        // counts must allocate in constant space without prebuilding an array.
        let first = budget.take()
        #expect(first >= 0 && first <= Int.max)
        if categoryCount == 1 {
            #expect(first == Int.max)
            #expect(budget.take() == 0)
        }
    }
}
