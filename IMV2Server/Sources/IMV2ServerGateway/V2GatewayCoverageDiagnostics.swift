import Foundation
import Synchronization

/// Passive, opt-in witnesses for account coverage that is still not Ready ten
/// seconds after its current Recovering transition. Correlation uses the TCP
/// source port and heartbeat request, never an account, room, IP or credential.
/// One fixed ring retains the latest observation per port, bounded per process.
protocol V2GatewayCoveragePortExample: Sendable { var sourcePort: Int { get } }

enum V2GatewayCoverageDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["IM_V2_GATEWAY_COVERAGE_DIAGNOSTICS"] == "true"
    typealias Examples = ExampleStore<Example>
    static let examples = Examples()
    static let roomExamples = ExampleStore<RoomExample>()
    struct RoomExample: Encodable, V2GatewayCoveragePortExample {
        let sourcePort: Int
        let requestID: UInt64
        let clientTimeMilliseconds: UInt64
        let observedAtUnixMilliseconds: Int64
        let requestedGeneration: UInt64
        let authorityGeneration: UInt64?
        let absence: String?
        let highWatermark: UInt64?
        let socketReady: Bool
        let retainedHead: Bool
        let headWriterOwned: Bool
        let pendingStates: [String]
    }
    struct Recovery: Encodable, Sendable {
        let current: Bool
        let generation: UInt64?
        let demand: Bool
        let attempts: Int?
        let placement: String?
        let installed: Bool
        let interestAcquired: Bool
        let currentCoverage: Bool
        let validCoverage: Bool
        let retainedReady: Bool
        let pendingRecovering: Bool
        let actualJob: Bool
        let outbound: Bool
        let requiredHead: UInt64?
        let retainedHead: UInt64?
    }
    struct Example: Encodable, V2GatewayCoveragePortExample {
        let sourcePort: Int
        let requestID: UInt64
        let clientTimeMilliseconds: UInt64
        let observedAtUnixMilliseconds: Int64
        let generation: UInt64
        let lastAdmittedState: String?
        let pendingStates: [String]
        let writeInFlight: Bool
        let retryOwned: Bool
        let scopeRejectedRevision: UInt64?
        let recovery: Recovery
    }
    final class ExampleStore<Value: V2GatewayCoveragePortExample>: Sendable {
        private struct State: Sendable {
            var entries: [Value?]
            var positions: [Int: Int] = [:]
            var next = 0
        }
        private let state: Mutex<State>
        init(capacity: Int = 512) {
            precondition(capacity > 0)
            state = Mutex(State(entries: Array(repeating: nil, count: capacity)))
        }
        func record(_ example: Value) {
            state.withLock { state in
                if let index = state.positions[example.sourcePort] { state.entries[index] = example; return }
                let index = state.next
                if let old = state.entries[index] { state.positions.removeValue(forKey: old.sourcePort) }
                state.entries[index] = example; state.positions[example.sourcePort] = index
                state.next = (index + 1) % state.entries.count
            }
        }
        func snapshot() -> [Value] { state.withLock { $0.entries.compactMap { $0 } } }
        func remove(sourcePort: Int) {
            state.withLock { state in
                guard let index = state.positions.removeValue(forKey: sourcePort) else { return }
                state.entries[index] = nil
            }
        }
    }
    static func renderRooms(_ values: [RoomExample]? = nil) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (values ?? roomExamples.snapshot()).compactMap { example in
            guard let data = try? encoder.encode(example), let json = String(data: data, encoding: .utf8) else { return nil }
            return "# im_v2_room_coverage_wait_example \(json)\n"
        }.joined()
    }
    static func render(_ values: [Example]? = nil) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (values ?? examples.snapshot()).compactMap { example in
            guard let data = try? encoder.encode(example), let json = String(data: data, encoding: .utf8) else { return nil }
            return "# im_v2_account_coverage_wait_example \(json)\n"
        }.joined()
    }
}
