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
    public typealias Sink = @Sendable (Snapshot) -> Void
    // Store a reference rather than repeatedly copying a closure through
    // Mutex.withLock. Optimized Swift builds can accumulate reabstraction
    // thunks on those copies until invoking the sink exhausts the stack.
    private final class SinkBox: Sendable {
        let callback: Sink
        init(_ callback: @escaping Sink) { self.callback = callback }
        func emit(_ snapshot: Snapshot) { callback(snapshot) }
    }
    private static let sink = Mutex<SinkBox?>(nil)
    @TaskLocal public static var current: V2SendPathTrace?
    private let segment: String
    private let startedAt = ContinuousClock.now
    private let wallStartedAt = Date()
    private struct State: Sendable { var operations: [String] = []; var spans: [Span] = []; var finished = false }
    private let state = Mutex(State())

    public static func installSink(_ value: Sink?) { sink.withLock { $0 = value.map(SinkBox.init) } }
    public static var enabled: Bool { sink.withLock { $0 != nil } }
    public init(operations: [String], segment: String) {
        self.segment = segment
        state.withLock { $0.operations = Array(operations.prefix(128)) }
    }
    public func setOperation(_ id: String) {
        state.withLock { if !$0.finished && $0.operations.isEmpty { $0.operations = [id] } }
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
        let span = Span(stage: stage, startMilliseconds: Self.milliseconds(startedAt.duration(to: start)),
                        durationMilliseconds: Self.milliseconds(start.duration(to: end)))
        state.withLock { if !$0.finished && $0.spans.count < 128 { $0.spans.append(span) } }
    }
    public func finish() {
        let snapshot = state.withLock { value -> Snapshot? in
            guard !value.finished else { return nil }; value.finished = true
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
