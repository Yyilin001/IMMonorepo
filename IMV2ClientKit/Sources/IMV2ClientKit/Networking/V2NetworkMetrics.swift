import Foundation
import IMV2Core

/// Deliberately excludes URLs, headers, identifiers, bodies and error descriptions.
public struct V2NetworkMetric: Sendable {
    public let service: String
    public let elapsed: TimeInterval
    public let receivedBytes: Int
    public let statusCode: Int?
    public let failure: V2HTTPFailure.Kind?
    public let cancelled: Bool
    public let queued: TimeInterval
    public let priority: V2NetworkWorkPriority
    public let isRetry: Bool
    public let certainty: V2HTTPFailure.Certainty
    public let phases: V2HTTPPhaseTiming?
    public let transactionCount: Int
    public let reusedConnection: Bool
    public init(service: String, elapsed: TimeInterval, receivedBytes: Int, statusCode: Int?, failure: V2HTTPFailure.Kind?,
                cancelled: Bool, transactionCount: Int, reusedConnection: Bool, queued: TimeInterval = 0,
                priority: V2NetworkWorkPriority = .interactive, isRetry: Bool = false,
                certainty: V2HTTPFailure.Certainty = .outcomeUnknown, phases: V2HTTPPhaseTiming? = nil) {
        self.service = ["account", "accountAPI", "authentication", "realtime", "resourceUpload", "mediaProvider", "media"].contains(service) ? service : "other"
        self.elapsed = elapsed; self.receivedBytes = max(0, receivedBytes); self.statusCode = statusCode
        self.failure = failure; self.cancelled = cancelled; self.transactionCount = max(0, transactionCount)
        self.reusedConnection = reusedConnection; self.queued = queued; self.priority = priority
        self.isRetry = isRetry; self.certainty = certainty; self.phases = phases
    }

}

/// Missing URLSession phases remain nil (for example, a reused connection).
public struct V2HTTPPhaseTiming: Sendable {
    public let dns: TimeInterval?
    public let connect: TimeInterval?
    public let tls: TimeInterval?
    public let request: TimeInterval?
    public let response: TimeInterval?
    public let networkProtocol: String?
    static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let value = end.timeIntervalSince(start)
        return value.isFinite && value >= 0 ? value : nil
    }
}

/// Handler timing is separate from network admission, decoding and SQLite
/// commit timing. Journal states are observations, never proof manufactured
/// from a successful handler return.
public struct V2OperationStepMetric: Sendable {
    public enum Completion: String, Sendable { case returned, threw, cancelled }
    public let kind: V2OperationKind
    public let action: V2OperationWorkAction
    public let attempt: Int
    public let priority: V2NetworkWorkPriority
    public let candidateWait: TimeInterval
    public let handlerElapsed: TimeInterval
    public let completion: Completion
    public let execution: V2OperationExecutionState?
    public let scheduling: V2OperationSchedulingState?
    public var certainty: V2HTTPFailure.Certainty {
        guard let execution else { return .outcomeUnknown }
        switch execution {
        case .committed, .rejected, .conflicted, .closed: return .responseReceived
        case .prepared, .cancelledLocally, .expiredUnsubmitted: return .notStarted
        case .submitting, .processing, .awaitingConfirmation: return .outcomeUnknown
        }
    }
}

/// Account-local diagnostics retain a fixed window and never retain URLSession
/// transactions, credentials, identifiers or free-form error descriptions.
public final class V2NetworkDiagnostics: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let recorded: UInt64
        public let httpRecorded: UInt64
        public let operationRecorded: UInt64
        public let projectionRecorded: UInt64
        public let backgroundRecorded: UInt64
        public let backgrounds: [V2BackgroundTransferMetric]
        public let resourceRecorded: UInt64
        public let resources: [V2ResourceTransferMetric]
        public let projections: [V2ProjectionMetric]
        public let samples: [V2NetworkMetric]
        public let operationSteps: [V2OperationStepMetric]
    }
    public enum ObservationError: Error { case overloaded }
    private let lock = NSLock()
    private var samples: [V2NetworkMetric] = []
    private var operationSteps: [V2OperationStepMetric] = []
    private var recorded: UInt64 = 0
    private var httpRecorded: UInt64 = 0
    private var operationRecorded: UInt64 = 0
    private var projectionRecorded: UInt64 = 0
    private var backgroundRecorded: UInt64 = 0
    private var backgrounds: [V2BackgroundTransferMetric] = []
    private var resourceRecorded: UInt64 = 0
    private var resources: [V2ResourceTransferMetric] = []
    private var projections: [V2ProjectionMetric] = []
    private var closed = false
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    public init() {}
    public func snapshot() -> Snapshot { lock.withLock { .init(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded, projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds, resourceRecorded: resourceRecorded, resources: resources, projections: projections, samples: samples, operationSteps: operationSteps) } }
    public func record(_ metric: V2NetworkMetric) {
        guard metric.elapsed.isFinite, metric.elapsed >= 0, metric.queued.isFinite, metric.queued >= 0 else { return }
        lock.withLock {
            guard !closed else { return }
            recorded = recorded == UInt64.max ? recorded : recorded + 1
            httpRecorded = httpRecorded == UInt64.max ? httpRecorded : httpRecorded + 1
            if samples.count == 128 { samples.removeFirst() }
            samples.append(metric)
            let value = Snapshot(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded, projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds, resourceRecorded: resourceRecorded, resources: resources, projections: projections, samples: samples, operationSteps: operationSteps)
            for observer in observers.values { observer.yield(value) }
        }
    }
    public func record(_ metric: V2OperationStepMetric) {
        guard metric.candidateWait.isFinite, metric.candidateWait >= 0,
              metric.handlerElapsed.isFinite, metric.handlerElapsed >= 0 else { return }
        lock.withLock {
            guard !closed else { return }
            recorded = recorded == UInt64.max ? recorded : recorded + 1
            operationRecorded = operationRecorded == UInt64.max ? operationRecorded : operationRecorded + 1
            if operationSteps.count == 128 { operationSteps.removeFirst() }
            operationSteps.append(metric)
            let value = Snapshot(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded, projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds, resourceRecorded: resourceRecorded, resources: resources, projections: projections, samples: samples, operationSteps: operationSteps)
            for observer in observers.values { observer.yield(value) }
        }
    }
    public func record(_ metric: V2ProjectionMetric) {
        guard metric.elapsed.isFinite, metric.elapsed >= 0 else { return }
        lock.withLock {
            guard !closed else { return }
            recorded = recorded == UInt64.max ? recorded : recorded + 1
            projectionRecorded = projectionRecorded == UInt64.max ? projectionRecorded : projectionRecorded + 1
            if projections.count == 128 { projections.removeFirst() }
            projections.append(metric)
            let value = Snapshot(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded,
                projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds, resourceRecorded: resourceRecorded, resources: resources, projections: projections, samples: samples, operationSteps: operationSteps)
            for observer in observers.values { observer.yield(value) }
        }
    }
    public func record(_ metric: V2ResourceTransferMetric) {
        guard metric.elapsed.isFinite, metric.elapsed >= 0,
              metric.bodyBytesSent >= 0, metric.bodyBytesReceived >= 0 else { return }
        lock.withLock {
            guard !closed else { return }
            recorded = recorded == UInt64.max ? recorded : recorded + 1
            resourceRecorded = resourceRecorded == UInt64.max ? resourceRecorded : resourceRecorded + 1
            if resources.count == 128 { resources.removeFirst() }
            resources.append(metric)
            let value = Snapshot(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded,
                projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds, resourceRecorded: resourceRecorded, resources: resources,
                projections: projections, samples: samples, operationSteps: operationSteps)
            for observer in observers.values { observer.yield(value) }
        }
    }
    public func record(_ metric: V2BackgroundTransferMetric) {
        lock.withLock {
            guard !closed else { return }
            recorded = recorded == UInt64.max ? recorded : recorded + 1
            backgroundRecorded = backgroundRecorded == UInt64.max ? backgroundRecorded : backgroundRecorded + 1
            if backgrounds.count == 128 { backgrounds.removeFirst() }
            backgrounds.append(metric)
            let value = Snapshot(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded,
                projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds,
                resourceRecorded: resourceRecorded, resources: resources, projections: projections,
                samples: samples, operationSteps: operationSteps)
            for observer in observers.values { observer.yield(value) }
        }
    }
    public func updates() throws -> AsyncStream<Snapshot> {
        let id = UUID()
        let pair = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try lock.withLock {
            if closed { pair.continuation.finish(); return }
            guard observers.count < 8 else { throw ObservationError.overloaded }
            observers[id] = pair.continuation
            pair.continuation.yield(.init(recorded: recorded, httpRecorded: httpRecorded, operationRecorded: operationRecorded, projectionRecorded: projectionRecorded, backgroundRecorded: backgroundRecorded, backgrounds: backgrounds, resourceRecorded: resourceRecorded, resources: resources, projections: projections, samples: samples, operationSteps: operationSteps))
        }
        pair.continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return pair.stream
    }
    private func remove(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
    public func close() {
        let values = lock.withLock { closed = true; let values = Array(observers.values); observers.removeAll(); samples.removeAll(); operationSteps.removeAll(); projections.removeAll(); resources.removeAll(); backgrounds.removeAll(); return values }
        for value in values { value.finish() }
    }
}
