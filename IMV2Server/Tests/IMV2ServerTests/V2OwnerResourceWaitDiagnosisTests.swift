import Foundation
import Testing
@testable import IMV2ServerInfrastructure

@Suite("Owner ready wait resource classification")
struct V2OwnerResourceWaitDiagnosisTests {
    @Test("physical occupancy and delayed scheduler release partition waiting without double counting")
    func resourcePartition() {
        let start = ContinuousClock.now
        let windows = (0..<4).map { _ in V2OwnerResourceWaitDiagnosis.Window(created: start,
            borrowed: start + .milliseconds(2), returned: start + .milliseconds(12), released: start + .milliseconds(22)) }
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: windows, capacity: 4,
            from: start, to: start + .milliseconds(30))
        #expect(result["ready_slots_full_borrow_pending_sum"] == .milliseconds(2))
        #expect(result["ready_pool_fully_borrowed_sum"] == .milliseconds(10))
        #expect(result["ready_slots_full_return_pending_sum"] == .milliseconds(10))
        #expect(result["ready_slot_available_sum"] == .milliseconds(8))
        #expect(result.values.reduce(.zero, +) == .milliseconds(30))
    }
    @Test("one long physical loan cannot be mistaken for a saturated four-connection pool")
    func partialOccupancy() {
        let start = ContinuousClock.now
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: [
            .init(created: start - .seconds(1), borrowed: start - .seconds(1), returned: nil, released: nil)
        ], capacity: 4, from: start, to: start + .milliseconds(100))
        #expect(result == ["ready_slot_available_sum": .milliseconds(100)])
    }
}
