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
    }
    static func durations(windows: [Window], capacity: Int, from start: ContinuousClock.Instant,
                          to end: ContinuousClock.Instant) -> [String: Duration] {
        let boundaries = Set(windows.flatMap { [$0.created, $0.borrowed, $0.returned, $0.released].compactMap { $0 } }
            .filter { start < $0 && $0 < end }).union([start, end]).sorted()
        var result: [String: Duration] = [:]
        for (a, b) in zip(boundaries, boundaries.dropFirst()) {
            let slots = windows.filter { $0.created <= a && ($0.released == nil || a < $0.released!) }
            let borrowed = windows.filter { $0.borrowed.map { $0 <= a } ?? false }
                .filter { $0.returned == nil || a < $0.returned! }.count
            let category: String
            if borrowed >= capacity { category = "ready_pool_fully_borrowed_sum" }
            else if slots.count >= capacity {
                category = slots.contains { $0.returned.map { $0 <= a } ?? false }
                    ? "ready_slots_full_return_pending_sum" : "ready_slots_full_borrow_pending_sum"
            } else { category = "ready_slot_available_sum" }
            result[category, default: .zero] += a.duration(to: b)
        }
        return result
    }
}
