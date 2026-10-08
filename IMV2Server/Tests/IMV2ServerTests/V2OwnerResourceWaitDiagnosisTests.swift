import Foundation
import Testing
@testable import IMV2ServerInfrastructure

@Suite("Owner ready wait resource classification")
struct V2OwnerResourceWaitDiagnosisTests {
    @Test("acquisition milestones partition saturation into distinct pending phases")
    func acquisitionPhases() {
        let start = ContinuousClock.now
        let window = V2OwnerResourceWaitDiagnosis.Window(created: start,
            borrowed: start + .milliseconds(15), returned: start + .milliseconds(20), released: start + .milliseconds(23),
            taskStarted: start + .milliseconds(2), poolRequested: start + .milliseconds(5),
            assignmentPublished: start + .milliseconds(9), assignmentCallback: start + .milliseconds(14),
            hasAcquisitionMarkers: true)
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: [window], capacity: 1,
            from: start, to: start + .milliseconds(25))
        #expect(result["ready_slots_full_task_pending_sum"] == .milliseconds(2))
        #expect(result["ready_slots_full_pool_request_pending_sum"] == .milliseconds(3))
        #expect(result["ready_slots_full_assignment_pending_sum"] == .milliseconds(4))
        #expect(result["ready_slots_full_callback_pending_sum"] == .milliseconds(5))
        #expect(result["ready_slots_full_driver_pending_sum"] == .milliseconds(1))
        #expect(result["ready_pool_fully_borrowed_sum"] == .milliseconds(5))
        #expect(result["ready_slots_full_return_pending_sum"] == .milliseconds(3))
        #expect(result["ready_slot_available_sum"] == .milliseconds(2))
        #expect(result.values.reduce(.zero, +) == .milliseconds(25))
    }

    @Test("different pending phases remain mixed rather than claiming a unique cause")
    func mixedPhases() {
        let start = ContinuousClock.now
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: [
            .init(created: start, borrowed: nil, returned: nil, released: nil,
                  taskStarted: start, poolRequested: start, hasAcquisitionMarkers: true),
            .init(created: start, borrowed: nil, returned: nil, released: nil, hasAcquisitionMarkers: true)
        ], capacity: 2, from: start, to: start + .milliseconds(10))
        #expect(result == ["ready_slots_full_mixed_pending_sum": .milliseconds(10)])
    }

    @Test("request window clips earlier and later resource events")
    func clippedWindow() {
        let start = ContinuousClock.now
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: [
            .init(created: start - .seconds(1), borrowed: start - .milliseconds(1),
                  returned: start + .milliseconds(100), released: start + .milliseconds(101))
        ], capacity: 1, from: start, to: start + .milliseconds(10))
        #expect(result == ["ready_pool_fully_borrowed_sum": .milliseconds(10)])
        #expect(V2OwnerResourceWaitDiagnosis.durations(windows: [], capacity: 0, from: start, to: start).isEmpty)
    }
    @Test("physical occupancy and delayed scheduler release partition waiting without double counting")
    func resourcePartition() {
        let start = ContinuousClock.now
        let windows = (0..<4).map { _ in V2OwnerResourceWaitDiagnosis.Window(created: start,
            borrowed: start + .milliseconds(2), returned: start + .milliseconds(12), released: start + .milliseconds(22)) }
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: windows, capacity: 4,
            from: start, to: start + .milliseconds(30))
        #expect(result["ready_slots_full_unknown_pending_sum"] == .milliseconds(2))
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
    @Test("completed history and future loans do not alter a deferred request window")
    func unrelatedHistory() {
        let start = ContinuousClock.now
        let active = V2OwnerResourceWaitDiagnosis.Window(created: start - .milliseconds(1),
            borrowed: start + .milliseconds(2), returned: start + .milliseconds(8),
            released: start + .milliseconds(12), taskStarted: start - .milliseconds(1),
            poolRequested: start, hasAcquisitionMarkers: true)
        let history = (1...512).map { offset in
            V2OwnerResourceWaitDiagnosis.Window(created: start - .seconds(offset + 1),
                borrowed: start - .seconds(offset + 1), returned: start - .seconds(offset),
                released: start - .seconds(offset))
        }
        let future = V2OwnerResourceWaitDiagnosis.Window(created: start + .milliseconds(10),
            borrowed: start + .milliseconds(11), returned: nil, released: nil)
        let expected = V2OwnerResourceWaitDiagnosis.durations(windows: [active], capacity: 1,
            from: start, to: start + .milliseconds(10))
        let result = V2OwnerResourceWaitDiagnosis.durations(windows: history + [active, future], capacity: 1,
            from: start, to: start + .milliseconds(10))
        #expect(result == expected)
        #expect(result.values.reduce(.zero, +) == .milliseconds(10))
    }

}
