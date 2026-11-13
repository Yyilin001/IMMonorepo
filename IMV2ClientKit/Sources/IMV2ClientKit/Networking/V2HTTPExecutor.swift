import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct V2HTTPExecutionBudget: Sendable {
    public let timeout: TimeInterval
    public let maximumResponseBytes: Int
    public let deadline: ContinuousClock.Instant?
    public init(timeout: TimeInterval = 15, maximumResponseBytes: Int = 1_048_576, deadline: ContinuousClock.Instant? = nil) {
        self.timeout = timeout; self.maximumResponseBytes = maximumResponseBytes; self.deadline = deadline
    }
}

/// A local absolute budget shared by credentials, admission, transmission and 401 refresh.
/// Metadata stays in URLProtocol properties and is never sent as a request header.
public enum V2HTTPRequestDeadline {
    @TaskLocal public static var current: ContinuousClock.Instant?
    @TaskLocal static var authenticationAdmission: V2AccountWorkScheduler?
    private static let propertyKey = "IMV2.local.absolute-request-deadline"
    private final class Box: NSObject, @unchecked Sendable {
        let value: ContinuousClock.Instant
        init(_ value: ContinuousClock.Instant) { self.value = value }
    }
    public static func attach(_ deadline: ContinuousClock.Instant?, to request: inout URLRequest) {
        guard let deadline else { return }
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(Box(deadline), forKey: propertyKey, in: mutable)
        request = mutable as URLRequest
    }
    public static func deadline(for request: URLRequest) -> ContinuousClock.Instant? {
        (URLProtocol.property(forKey: propertyKey, in: request) as? Box)?.value
    }
    /// Cancels and drains the operation child before returning timeout/cancellation.
    /// Shared credential rotation remains owned by AuthSession; cancelling one waiter
    /// does not abandon that rotation or release its physical auth resources early.
    public static func run<Value: Sendable>(until deadline: ContinuousClock.Instant, service: String,
        certainty: V2HTTPFailure.Certainty = .notStarted,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        // Nested authentication or domain calls may tighten the caller's budget,
        // but must never grant themselves a fresh, longer request lifetime.
        let deadline = min(deadline, current ?? deadline)
        guard deadline > .now else { throw V2HTTPFailure(kind: .deadlineExceeded, service: service, certainty: certainty) }
        return try await $current.withValue(deadline) {
            try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw V2HTTPFailure(kind: .deadlineExceeded, service: service, certainty: certainty)
                }
                defer { group.cancelAll() }
                let value = try await group.next()!
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw V2HTTPFailure(kind: .deadlineExceeded, service: service, certainty: certainty)
                }
                return value
            }
        }
    }
}

/// Executes exactly once. Optional account admission happens at this leaf;
/// semantic retry belongs to the durable step or interactive query owner.
public final class V2HTTPExecutor: Sendable {
    private let qualityObserver: V2QualityObserver?
    private let scheduler: V2AccountWorkScheduler?
    private let transport: any V2HTTPTransport
    private let metrics: @Sendable (V2NetworkMetric) -> Void
    public init(session: URLSession = V2SecureURLSession.account, scheduler: V2AccountWorkScheduler? = nil, qualityObserver: V2QualityObserver? = nil, metrics: @escaping @Sendable (V2NetworkMetric) -> Void = { _ in }) {
        self.transport = V2URLSessionHTTPTransport(session: session); self.scheduler = scheduler; self.qualityObserver = qualityObserver; self.metrics = metrics
    }
    public init(transport: any V2HTTPTransport, scheduler: V2AccountWorkScheduler? = nil,
                qualityObserver: V2QualityObserver? = nil, metrics: @escaping @Sendable (V2NetworkMetric) -> Void = { _ in }) {
        self.transport = transport; self.scheduler = scheduler; self.qualityObserver = qualityObserver; self.metrics = metrics
    }
    public func execute(_ request: URLRequest, budget: V2HTTPExecutionBudget = .init(), service: String = "account",
                        workContext: V2NetworkWorkContext? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let scheduler else { return try await executeUnscheduled(request, budget: budget, service: service) }
        if V2HTTPRequestDeadline.authenticationAdmission === scheduler,
           service == "authentication" || workContext?.kind == .authentication {
            // The credential owner already holds this account's reserved channel and
            // drains the shared rotation before release. Do not acquire it twice.
            return try await executeUnscheduled(request, budget: budget, service: service)
        }
        guard budget.timeout.isFinite, budget.timeout > 0, budget.timeout <= 86_400 else {
            throw V2HTTPFailure(kind: .invalidEndpoint, service: service, certainty: .notStarted)
        }
        let deadline = min([budget.deadline, V2HTTPRequestDeadline.current, V2HTTPRequestDeadline.deadline(for: request)].compactMap { $0 }.min() ?? .now.advanced(by: .seconds(budget.timeout)),
                           .now.advanced(by: .seconds(budget.timeout)))
        let context: V2NetworkWorkContext
        if let scoped = V2NetworkWorkScope.context {
            context = .init(service: workContext?.service ?? service, priority: scoped.priority,
                kind: workContext?.kind ?? scoped.kind, orderingKey: workContext?.orderingKey ?? scoped.orderingKey,
                isRetry: scoped.isRetry || (workContext?.isRetry ?? false))
        } else { context = workContext ?? .init(service: service) }
        let queuedAt = ContinuousClock.now
        let permit: V2RequestPermit
        do { permit = try await scheduler.acquire(context, deadline: deadline) }
        catch {
            let queued = queuedAt.duration(to: .now).components
            let seconds = Double(queued.seconds) + Double(queued.attoseconds) / 1e18
            let timedOut = (error as? V2AccountWorkScheduler.AdmissionError) == .deadlineExceeded
            metrics(.init(service: service, elapsed: 0, receivedBytes: 0, statusCode: nil,
                failure: timedOut ? .deadlineExceeded : nil, cancelled: error is CancellationError || Task.isCancelled,
                transactionCount: 0, reusedConnection: false, queued: seconds,
                priority: context.priority, isRetry: context.isRetry, certainty: .notStarted))
            if timedOut { throw V2HTTPFailure(kind: .deadlineExceeded, service: service, certainty: .notStarted) }
            throw error
        }
        let queueDuration = queuedAt.duration(to: .now).components
        let queueSeconds = Double(queueDuration.seconds) + Double(queueDuration.attoseconds) / 1e18
        let scheduledBudget = V2HTTPExecutionBudget(timeout: budget.timeout, maximumResponseBytes: budget.maximumResponseBytes, deadline: deadline)
        do {
            let result = try await executeUnscheduled(request, budget: scheduledBudget, service: service, queued: queueSeconds, context: context) { response in
                if response.statusCode == 429 || response.statusCode == 503,
                   let until = V2HTTPFailure.status(response, service: service).retryAfter {
                    // Headers govern admission even when the error body stalls or
                    // exceeds its cap. Start delta-seconds at header receipt.
                    await scheduler.coolDown(service: context.service, for: until.timeIntervalSinceNow)
                }
            }
            _ = await scheduler.release(permit)
            await observe(result.1.statusCode == 429 || result.1.statusCode == 503 ? .serviceCooldown : .success, service: service)
            return result
        } catch {
            _ = await scheduler.release(permit)
            if let failure = error as? V2HTTPFailure, failure.certainty != .notStarted {
                if failure.statusCode == 429 || failure.statusCode == 503 { await observe(.serviceCooldown, service: service) }
                else if failure.kind == .deadlineExceeded { await observe(.timeout, service: service) }
                else if failure.kind == .transport { await observe(.transportFailure, service: service) }
            }
            throw error
        }
    }
    private func observe(_ sample: V2QualityObserver.Sample, service: String) async {
        guard let qualityObserver, let scheduler else { return }
        let quality = await qualityObserver.record(sample, service: service, now: ProcessInfo.processInfo.systemUptime)
        await scheduler.setServiceDegraded(service, quality == .degraded)
    }
    private func executeUnscheduled(_ request: URLRequest, budget: V2HTTPExecutionBudget, service: String,
                                    queued: TimeInterval = 0, context: V2NetworkWorkContext? = nil,
                                    onResponse: @escaping @Sendable (HTTPURLResponse) async -> Void = { _ in }) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              budget.timeout.isFinite, budget.timeout > 0, budget.timeout <= 86_400, budget.maximumResponseBytes >= 0 else {
            throw V2HTTPFailure(kind: .invalidEndpoint, service: service, certainty: .notStarted)
        }
        let start = ContinuousClock.now
        let deadline = min([budget.deadline, V2HTTPRequestDeadline.current, V2HTTPRequestDeadline.deadline(for: request)].compactMap { $0 }.min() ?? start.advanced(by: .seconds(budget.timeout)), start.advanced(by: .seconds(budget.timeout)))
        guard deadline > start else { throw V2HTTPFailure(kind: .deadlineExceeded, service: service, certainty: .notStarted) }
        let connectivity = V2ResourceConnectivityObservation()
        let delegate = transport.makeExecution(events: .init(waiting: { connectivity.waiting() }, active: { connectivity.finish() }))
        var count = 0
        var status: Int?
        var failure: V2HTTPFailure.Kind?
        var cancelled = false
        var certainty = V2HTTPFailure.Certainty.outcomeUnknown
        defer {
            let duration = start.duration(to: .now).components
            let observation = delegate.observation
            let elapsed: TimeInterval = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let scoped = V2NetworkWorkScope.context
            let priority: V2NetworkWorkPriority = context?.priority ?? scoped?.priority ?? .interactive
            let isRetry: Bool = context?.isRetry ?? scoped?.isRetry ?? false
            let sample = V2NetworkMetric(service: service, elapsed: elapsed,
                receivedBytes: max(count, observation.2), statusCode: status ?? observation.3,
                failure: failure, cancelled: cancelled, transactionCount: observation.0,
                reusedConnection: observation.1, queued: queued, priority: priority,
                isRetry: isRetry, certainty: certainty, phases: delegate.phaseTiming)
            metrics(sample)
        }
        do {
            let result = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
                group.addTask {
                    try await delegate.execute(request, maximumResponseBytes: budget.maximumResponseBytes,
                        service: service, onResponse: onResponse)
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    delegate.cancel()
                    throw V2HTTPFailure(kind: .deadlineExceeded, service: service, statusCode: delegate.observation.3)
                }
                defer { group.cancelAll(); delegate.cancel() }
                return try await group.next()!
            }
            } onCancel: { delegate.cancel() }
            count = result.0.count; status = result.1.statusCode; certainty = .responseReceived
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            cancelled = true; delegate.cancel(); throw CancellationError()
        } catch let error as V2HTTPFailure {
            failure = error.kind; status = error.statusCode; certainty = error.certainty; throw error
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { cancelled = true; throw CancellationError() }
            failure = .transport
            throw V2HTTPFailure(kind: .transport, service: service, statusCode: delegate.observation.3, urlErrorCode: error.code.rawValue)
        } catch {
            failure = .transport
            throw V2HTTPFailure(kind: .transport, service: service, statusCode: delegate.observation.3)
        }
    }
}
