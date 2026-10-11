import Foundation
import IMV2Core

/// Admission measures retained models, not their wire representation. The
/// common send command has an immutable cost calculated at construction.
/// Other bounded control models use conservative accounting without encoding.
package protocol V2ActorBudgetedPayload: Sendable { var actorRetainedBytes: Int { get } }

public enum V2ActorPayloadBudget {
    public static func retainedBytes<T>(of value: T) -> Int {
        var remaining = 1_000_000
        return measure(value, depth: 0, remaining: &remaining)
    }
    package static func reflectedBytes<T>(of value: T) -> Int {
        var remaining = 1_000_000
        return measure(value, depth: 0, remaining: &remaining, skipKnown: true)
    }
    package static func textBytes(_ value: String) -> Int { adding(64, adding(value.utf8.count, value.utf8.count)) }
    package static func dataBytes(_ value: Data) -> Int { adding(64, value.count) }
    package static func sum(_ values: Int...) -> Int { values.reduce(0, adding) }
    private static func measure(_ value: Any, depth: Int, remaining: inout Int, skipKnown: Bool = false) -> Int {
        guard depth < 64, remaining > 0 else { return Int.max }
        remaining -= 1
        if !skipKnown, let known = value as? any V2ActorBudgetedPayload { return known.actorRetainedBytes }
        if let command = value as? V2MessageSendOperationCommand { return command.estimatedRetainedBytes }
        if let data = value as? Data { return adding(64, data.count) }
        if let string = value as? String { return adding(64, adding(string.utf8.count, string.utf8.count)) }
        if let url = value as? URL { return measure(url.absoluteString, depth: depth + 1, remaining: &remaining) }
        if value is UUID || value is Date { return 32 }
        let mirror = Mirror(reflecting: value)
        // No runtime model should retain reference cycles. Caches are private
        // implementation details, and must not be traversed as domain payloads.
        if mirror.displayStyle == .class { return Int.max }
        var total = 32
        for child in mirror.children {
            total = adding(total, measure(child.value, depth: depth + 1, remaining: &remaining))
            if total == Int.max { break }
        }
        return total
    }
    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
