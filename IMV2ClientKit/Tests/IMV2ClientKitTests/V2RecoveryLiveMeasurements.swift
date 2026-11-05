import Foundation
import Synchronization

/// Fixed stage names only; no user, room, message identifiers or payloads.
final class LiveRecoveryMeasurements: Sendable {
    private let values = Mutex<[String: [Double]]>([:])
    func reset() { values.withLock { $0 = [:] } }
    func record(_ name: String, since start: ContinuousClock.Instant) {
        let d = start.duration(to: .now).components
        record(name, milliseconds: Double(d.seconds)*1000 + Double(d.attoseconds)/1e15)
    }
    func record(_ name: String, milliseconds: Double) { values.withLock { $0[name, default: []].append(milliseconds) } }
    static func summary(_ samples: [Double]) -> [String: Double] {
        let s = samples.sorted()
        func p(_ f: Double) -> Double { s.isEmpty ? 0 : s[min(s.count-1, Int(Double(s.count-1)*f))] }
        return ["count": Double(s.count), "sum_ms": s.reduce(0,+), "p50_ms": p(0.5), "p95_ms": p(0.95), "p99_ms": p(0.99), "max_ms": s.last ?? 0]
    }
    func write(to url: URL) throws {
        let result = values.withLock { $0.mapValues(Self.summary) }
        try JSONEncoder().encode(result).write(to: url, options: .atomic)
    }
}
