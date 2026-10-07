import Foundation
import Logging
import Synchronization

/// Opt-in diagnosis only. Record outside the measured authority critical section.
final class V2RoomAuthorityLockDiagnostics: Sendable {
    struct Totals: Codable, Sendable {
        var count: UInt64 = 0
        var waitMilliseconds: Double = 0
        var heldMilliseconds: Double = 0
        var maximumWaitMilliseconds: Double = 0
        var maximumHeldMilliseconds: Double = 0
    }
    private struct State: Sendable {
        var totals: [String: Totals] = [:]
        var nextReport = ContinuousClock.now + .seconds(5)
        var slowReports = 0
    }
    private let state = Mutex(State())
    private let logger = Logger(label: "im.v2.room.authority.lock")

    func record(operation: String, wait: Duration, held: Duration) {
        let waitMS = Self.milliseconds(wait), heldMS = Self.milliseconds(held)
        let now = ContinuousClock.now
        let output = state.withLock { value -> ([String: Totals]?, Bool) in
            var item = value.totals[operation, default: .init()]
            item.count += 1
            item.waitMilliseconds += waitMS; item.heldMilliseconds += heldMS
            item.maximumWaitMilliseconds = max(item.maximumWaitMilliseconds, waitMS)
            item.maximumHeldMilliseconds = max(item.maximumHeldMilliseconds, heldMS)
            value.totals[operation] = item
            let report: [String: Totals]?
            if now >= value.nextReport {
                value.nextReport = now + .seconds(5)
                value.slowReports = 0
                report = value.totals
            } else { report = nil }
            let slow = max(waitMS, heldMS) >= 20 && value.slowReports < 16
            if slow { value.slowReports += 1 }
            return (report, slow)
        }
        if let report = output.0, let data = try? JSONEncoder().encode(report),
           let json = String(data: data, encoding: .utf8) {
            logger.notice("Room authority lock totals", metadata: ["room_authority_lock": .string(json)])
        }
        if output.1 {
            logger.warning("Slow room authority lock", metadata: [
                "operation": .string(operation), "wait_ms": .string(String(waitMS)),
                "held_ms": .string(String(heldMS)),
                "observed_unix_ms": .string(String(Date().timeIntervalSince1970 * 1000))])
        }
    }

    func snapshot() -> [String: Totals] { state.withLock { $0.totals } }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return max(0, Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
    }
}
