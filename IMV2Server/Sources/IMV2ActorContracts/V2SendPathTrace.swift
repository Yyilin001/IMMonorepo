import Foundation
import Synchronization

/// Bounded diagnostic spans, never used as authority or as metric labels.
/// Operation UUIDs correlate actor and gateway segments without logging accounts,
/// rooms, payloads or credentials. All timing uses a monotonic clock.
public final class V2SendPathTrace: Sendable {
    public struct Span: Codable, Sendable {
        public let stage: String
        public let startMilliseconds: Double
        public let durationMilliseconds: Double
    }
    public struct Snapshot: Codable, Sendable {
        public let operations: [String]
        public let segment: String
        public let startedAtUnixMilliseconds: Int64
        public let durationMilliseconds: Double
        public let spans: [Span]
    }
    public enum Collection: Sendable {
        case all
        case sampledOperations

        public func includes(_ operations: [String]) -> Bool {
            switch self {
            case .all: return true
            case .sampledOperations:
                return operations.contains { UUID(uuidString: $0).map { $0.uuid.0 < 4 } ?? false }
            }
        }
    }
    public typealias Sink = @Sendable (Snapshot) -> Void
    // Store a reference rather than repeatedly copying a closure through
    // Mutex.withLock. Optimized Swift builds can accumulate reabstraction
    // thunks on those copies until invoking the sink exhausts the stack.
    private final class SinkBox: Sendable {
        let callback: Sink
        let collection: Collection
        init(_ callback: @escaping Sink, collection: Collection) {
            self.callback = callback; self.collection = collection
        }
        func emit(_ snapshot: Snapshot) { callback(snapshot) }
    }
    private static let sink = Mutex<SinkBox?>(nil)
    @TaskLocal public static var current: V2SendPathTrace?
    private let segment: String
    private let collection: Collection
    private let startedAt = ContinuousClock.now
    private let wallStartedAt = Date()
    private struct State: Sendable { var operations: [String] = []; var spans: [Span] = []; var finished = false; var collecting = true }
    private let state = Mutex(State())

    public static func installSink(_ value: Sink?, collection: Collection = .all) {
        sink.withLock { $0 = value.map { SinkBox($0, collection: collection) } }
    }
    public static func shouldCollect(operations: [String]) -> Bool {
        sink.withLock { $0?.collection.includes(operations) ?? false }
    }
    public static var enabled: Bool { sink.withLock { $0 != nil } }
    public init(operations: [String], segment: String) {
        self.segment = segment
        collection = Self.sink.withLock { $0?.collection ?? .all }
        state.withLock {
            $0.operations = Array(operations.prefix(128))
            // Gateway learns the authenticated operation after protobuf decoding.
            // Maintenance observations do not have message operation IDs.
            $0.collecting = operations.isEmpty || collection.includes(operations)
        }
    }
    public func setOperation(_ id: String) {
        state.withLock {
            if !$0.finished && $0.operations.isEmpty {
                $0.operations = [id]
                $0.collecting = collection.includes([id])
                if !$0.collecting { $0.spans.removeAll() }
            }
        }
    }
    /// A boundary within this segment's monotonic timeline, not a duration.
    public func mark(_ stage: String) {
        let now = ContinuousClock.now
        record(stage, from: now, to: now)
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let p = duration.components
        return Double(p.seconds) * 1_000 + Double(p.attoseconds) / 1e15
    }
    public func record(_ stage: String, from start: ContinuousClock.Instant,
                       to end: ContinuousClock.Instant = .now) {
        state.withLock {
            guard $0.collecting, !$0.finished, $0.spans.count < 128 else { return }
            $0.spans.append(Span(stage: stage,
                startMilliseconds: Self.milliseconds(startedAt.duration(to: start)),
                durationMilliseconds: Self.milliseconds(start.duration(to: end))))
        }
    }
    public func finish() {
        let snapshot = state.withLock { value -> Snapshot? in
            guard !value.finished else { return nil }; value.finished = true
            guard value.collecting else { return nil }
            // Room traces start at dispatch, but must include earlier queue wait
            // in both slow-request selection and their normalized timeline.
            let offset = min(0, value.spans.map(\.startMilliseconds).min() ?? 0)
            let spans = value.spans.map { Span(stage: $0.stage,
                startMilliseconds: $0.startMilliseconds - offset,
                durationMilliseconds: $0.durationMilliseconds) }
            return .init(operations: value.operations, segment: segment,
                startedAtUnixMilliseconds: Int64(wallStartedAt.timeIntervalSince1970 * 1_000 + offset),
                durationMilliseconds: Self.milliseconds(startedAt.duration(to: .now)) - offset, spans: spans)
        }
        if let snapshot { Self.sink.withLock { $0 }?.emit(snapshot) }
    }
}
