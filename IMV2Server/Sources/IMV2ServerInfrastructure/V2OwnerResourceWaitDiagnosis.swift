import Foundation
import IMV2ActorContracts

/// Bounded request-window diagnosis. Categories partition ready waiting time;
/// they are sums of possibly disjoint intervals, not SQL or CPU timings.
enum V2OwnerResourceWaitDiagnosis {
    struct Window: Sendable {
        let created: ContinuousClock.Instant
        let borrowed: ContinuousClock.Instant?
        let returned: ContinuousClock.Instant?
        let released: ContinuousClock.Instant?
        let taskStarted: ContinuousClock.Instant?
        let poolRequested: ContinuousClock.Instant?
        let assignmentPublished: ContinuousClock.Instant?
        let assignmentCallback: ContinuousClock.Instant?
        let hasAcquisitionMarkers: Bool

        init(created: ContinuousClock.Instant, borrowed: ContinuousClock.Instant?,
             returned: ContinuousClock.Instant?, released: ContinuousClock.Instant?,
             taskStarted: ContinuousClock.Instant? = nil, poolRequested: ContinuousClock.Instant? = nil,
             assignmentPublished: ContinuousClock.Instant? = nil, assignmentCallback: ContinuousClock.Instant? = nil,
             hasAcquisitionMarkers: Bool = false) {
            self.created = created; self.borrowed = borrowed; self.returned = returned; self.released = released
            self.taskStarted = taskStarted; self.poolRequested = poolRequested
            self.assignmentPublished = assignmentPublished; self.assignmentCallback = assignmentCallback
            self.hasAcquisitionMarkers = hasAcquisitionMarkers
        }

        func pendingCategory(at instant: ContinuousClock.Instant) -> String {
            // Absent markers in old/incomplete observations are unknown, not proof
            // that a task never ran. Later observed boundaries imply earlier phases.
            if assignmentCallback.map({ $0 <= instant }) == true { return "driver" }
            if assignmentPublished.map({ $0 <= instant }) == true { return "callback" }
            if poolRequested.map({ $0 <= instant }) == true { return "assignment" }
            if taskStarted.map({ $0 <= instant }) == true { return "pool_request" }
            if taskStarted != nil || hasAcquisitionMarkers { return "task" }
            return "unknown"
        }
    }
    static func durations(windows: [Window], capacity: Int, from start: ContinuousClock.Instant,
                          to end: ContinuousClock.Instant) -> [String: Duration] {
        guard capacity > 0, end > start else { return [:] }
        // Half-open resource intervals outside this request cannot contribute.
        // Filter before allocating event sets or sorting historical milestones.
        let windows = windows.filter { $0.created < end && ($0.released == nil || $0.released! > start) }
        // Sweep only changed tickets at each boundary. Rescanning every retained
        // ticket for every event would make slow-request diagnosis quadratic.
        var events: [ContinuousClock.Instant: Set<Int>] = [:]
        for (index, window) in windows.enumerated() {
            for time in [window.created, window.borrowed, window.returned, window.released,
                         window.taskStarted, window.poolRequested, window.assignmentPublished,
                         window.assignmentCallback].compactMap({ $0 }) where start < time && time < end {
                events[time, default: []].insert(index)
            }
        }
        let boundaries = Set(events.keys).union([start, end]).sorted()
        typealias Status = (slot: Int, borrowed: Int, returned: Int, pending: String?)
        func status(_ window: Window, at time: ContinuousClock.Instant) -> Status {
            let slot = window.created <= time && (window.released == nil || time < window.released!)
            let borrowed = (window.borrowed.map { $0 <= time } ?? false)
                && (window.returned == nil || time < window.returned!)
            let returned = slot && (window.returned.map { $0 <= time } ?? false)
            return (slot ? 1 : 0, borrowed ? 1 : 0, returned ? 1 : 0,
                    slot && !borrowed && !returned ? window.pendingCategory(at: time) : nil)
        }
        var states = windows.map { status($0, at: start) }
        var slots = 0, borrowed = 0, returned = 0
        var phases: [String: Int] = [:]
        func apply(_ state: Status, sign: Int) {
            slots += state.slot * sign; borrowed += state.borrowed * sign; returned += state.returned * sign
            if let phase = state.pending { phases[phase, default: 0] += sign }
        }
        for state in states { apply(state, sign: 1) }
        var result: [String: Duration] = [:]
        for (a, b) in zip(boundaries, boundaries.dropFirst()) {
            for index in events[a] ?? [] {
                apply(states[index], sign: -1)
                states[index] = status(windows[index], at: a)
                apply(states[index], sign: 1)
            }
            let category: String
            if borrowed >= capacity { category = "ready_pool_fully_borrowed_sum" }
            else if slots >= capacity {
                if returned > 0 {
                    category = "ready_slots_full_return_pending_sum"
                } else {
                    let active = phases.filter { $0.value > 0 }.keys
                    let phase = active.count == 1 ? active.first! : "mixed"
                    category = "ready_slots_full_\(phase)_pending_sum"
                }
            } else { category = "ready_slot_available_sum" }
            result[category, default: .zero] += a.duration(to: b)
        }
        return result
    }
}
