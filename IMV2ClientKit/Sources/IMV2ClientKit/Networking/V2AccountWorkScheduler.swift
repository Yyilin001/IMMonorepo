import Foundation

public enum V2NetworkWorkPriority: Int, CaseIterable, Sendable { case critical, interactive, recovery, background }
public enum V2ByteTransferDirection: Equatable, Sendable { case upload, download }
public enum V2NetworkWorkKind: Equatable, Sendable {
    case ordinary, authentication, byteTransfer(V2ByteTransferDirection)
    var byteDirection: V2ByteTransferDirection? { if case .byteTransfer(let direction) = self { direction } else { nil } }
}
public struct V2NetworkWorkContext: Equatable, Sendable {
    public let service: String
    public let priority: V2NetworkWorkPriority
    public let kind: V2NetworkWorkKind
    public let orderingKey: String?
    /// Only additional attempts after failure consume the shared retry quota.
    public let isRetry: Bool
    public init(service: String, priority: V2NetworkWorkPriority = .interactive,
                kind: V2NetworkWorkKind = .ordinary, orderingKey: String? = nil, isRetry: Bool = false) {
        self.service = service; self.priority = priority; self.kind = kind; self.orderingKey = orderingKey
        self.isRetry = isRetry
    }
}
extension V2NetworkWorkContext {
    func promoting(to priority: V2NetworkWorkPriority) -> Self {
        .init(service: service, priority: priority.rawValue < self.priority.rawValue ? priority : self.priority,
            kind: kind, orderingKey: orderingKey, isRetry: isRetry)
    }
}
/// Construction is private to the scheduler; copies cannot release another scheduler's slot.
public struct V2RequestPermit: Sendable, Equatable {
    fileprivate let schedulerID: UUID
    fileprivate let id: UUID
    public let context: V2NetworkWorkContext
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.schedulerID == rhs.schedulerID && lhs.id == rhs.id }
}
public actor V2AccountWorkScheduler {
    public struct Configuration: Sendable {
        public let ordinaryLimit: Int
        public let serviceLimit: Int
        public let authenticationLimit: Int
        public let byteTransferLimit: Int
        public let uploadTransferLimit: Int
        public let downloadTransferLimit: Int
        public let interactiveByteReserve: Int
        public let byteTransferWaiterLimit: Int
        public let byteTransferAgingInterval: TimeInterval
        public let waiterLimit: Int
        public let controlWaiterLimit: Int
        public init(ordinaryLimit: Int = 6, serviceLimit: Int = 4, authenticationLimit: Int = 1,
                    byteTransferLimit: Int = 4, uploadTransferLimit: Int = 2, downloadTransferLimit: Int = 2,
                    interactiveByteReserve: Int = 1, byteTransferWaiterLimit: Int = 128,
                    byteTransferAgingInterval: TimeInterval = 15,
                    waiterLimit: Int = 256, controlWaiterLimit: Int = 64) {
            precondition(ordinaryLimit > 0 && serviceLimit > 0 && authenticationLimit > 0 && byteTransferLimit > 0 && waiterLimit >= 0 && controlWaiterLimit >= 0)
            precondition(uploadTransferLimit > 0 && downloadTransferLimit > 0 && interactiveByteReserve >= 0 && byteTransferWaiterLimit >= 0)
            precondition(byteTransferAgingInterval.isFinite && byteTransferAgingInterval > 0)
            self.ordinaryLimit = ordinaryLimit; self.serviceLimit = serviceLimit
            self.authenticationLimit = authenticationLimit; self.byteTransferLimit = byteTransferLimit; self.waiterLimit = waiterLimit
            self.controlWaiterLimit = controlWaiterLimit
            self.uploadTransferLimit = uploadTransferLimit; self.downloadTransferLimit = downloadTransferLimit
            self.interactiveByteReserve = interactiveByteReserve; self.byteTransferWaiterLimit = byteTransferWaiterLimit
            self.byteTransferAgingInterval = byteTransferAgingInterval
        }
    }
    public enum AdmissionError: Error, Sendable { case closed, overloaded, deadlineExceeded, invalidAdoption }
    public struct Snapshot: Sendable {
        public let active: Int; public let waiting: Int; public let closed: Bool
        public let activeUploads: Int; public let activeDownloads: Int; public let waitingByteTransfers: Int
        public let activeBackgroundTransfers: Int
    }
    private struct Waiter {
        let id: UUID; var context: V2NetworkWorkContext; let enqueuedAt: TimeInterval
        let continuation: CheckedContinuation<V2RequestPermit, any Error>
        let observation: V2ResourceTransferWaitReporter?
    }
    private let identity = UUID()
    private let configuration: Configuration
    private var active: [UUID: V2RequestPermit] = [:]
    private var adoptedTransfers: [UUID: UUID] = [:]
    private var waiters: [Waiter] = []
    private var closed = false
    private var degraded = false
    private var degradedServices = Set<String>()
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let wheel: [V2NetworkWorkPriority] = [.critical, .interactive, .critical, .interactive, .recovery, .critical, .interactive, .background, .critical, .interactive, .recovery]
    private var cursor = 0
    private struct ServiceAdmission {
        var retries: V2NetworkRetryTokenBucket
        var cooldownUntil: TimeInterval = 0
    }
    private let monotonicNow: @Sendable () -> TimeInterval
    private var serviceAdmission: [String: ServiceAdmission] = [:]
    private var admissionWake: Task<Void, Never>?
    public init(configuration: Configuration = .init(),
                monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration; self.monotonicNow = monotonicNow
    }
    public func snapshot() -> Snapshot {
        .init(active: active.count, waiting: waiters.count, closed: closed,
            activeUploads: active.values.filter { $0.context.kind.byteDirection == .upload }.count,
            activeDownloads: active.values.filter { $0.context.kind.byteDirection == .download }.count,
            waitingByteTransfers: waiters.filter { $0.context.kind.byteDirection != nil }.count,
            activeBackgroundTransfers: active.values.filter { $0.context.kind.byteDirection != nil && $0.context.priority == .background }.count)
    }
    /// Records already-running system I/O, rather than admitting another attempt.
    /// The account owner must reconcile all existing tasks before launching new work.
    /// Restored tasks may exceed today's limit; no new byte work starts until they drain.
    /// The opaque ID identifies one durable system task mapping, not a resource/job
    /// that can have several successive transfer attempts.
    public func adoptExistingByteTransfer(id: UUID, context: V2NetworkWorkContext) throws -> V2RequestPermit {
        guard !closed else { throw AdmissionError.closed }
        guard context.kind.byteDirection != nil else { throw AdmissionError.invalidAdoption }
        if let permitID = adoptedTransfers[id], let permit = active[permitID] {
            guard permit.context == context else { throw AdmissionError.invalidAdoption }
            return permit
        }
        if serviceAdmission[context.service] == nil {
            guard serviceAdmission.count < 64 else { throw AdmissionError.overloaded }
            serviceAdmission[context.service] = .init(retries: .init(now: monotonicNow()))
        }
        // The system has already started this transfer. Neither cooldown nor an
        // exhausted retry bucket can make those physical bytes cease to exist.
        let permit = V2RequestPermit(schedulerID: identity, id: UUID(), context: context)
        active[permit.id] = permit
        adoptedTransfers[id] = permit.id
        return permit
    }
    public func setDegraded(_ value: Bool) { degraded = value; dispatch() }
    /// Corrects the classification of already-running bytes without granting
    /// another permit or releasing the physical transfer. This is app admission
    /// accounting, not a promise to change the OS background scheduling policy.
    func promoteDownloadPermit(_ permit: V2RequestPermit, to priority: V2NetworkWorkPriority) -> V2RequestPermit? {
        guard !closed, permit.schedulerID == identity, let current = active[permit.id],
              current.context.kind == .byteTransfer(.download) else { return nil }
        let updated = V2RequestPermit(schedulerID: identity, id: current.id, context: current.context.promoting(to: priority))
        active[current.id] = updated
        dispatch()
        return updated
    }
    public func setServiceDegraded(_ service: String, _ value: Bool) {
        if value && degradedServices.count < 64 { degradedServices.insert(service) }
        if !value { degradedServices.remove(service) }
        dispatch()
    }
    /// A server cooldown affects this service's ordinary/byte traffic, including
    /// new requests; authentication retains its independently governed channel.
    public func coolDown(service: String, for seconds: TimeInterval) {
        guard !closed, seconds.isFinite, seconds > 0, serviceAdmission[service] != nil else { return }
        serviceAdmission[service]!.cooldownUntil = max(serviceAdmission[service]!.cooldownUntil, monotonicNow() + seconds)
        dispatch()
    }
    public func acquire(_ context: V2NetworkWorkContext, deadline: ContinuousClock.Instant? = nil) async throws -> V2RequestPermit {
        try Task.checkCancellation()
        guard !closed else { throw AdmissionError.closed }
        if context.kind != .authentication, serviceAdmission[context.service] == nil {
            guard serviceAdmission.count < 64 else { throw AdmissionError.overloaded }
            serviceAdmission[context.service] = .init(retries: .init(now: monotonicNow()))
        }
        let id = UUID()
        let demand = context.kind == .byteTransfer(.download) ? V2ByteTransferWorkScope.demand : nil
        defer { demand?.removeObserver(id) }
        let expiry: Task<Void, Never>? = deadline.map { instant in
            Task { [weak self] in
                do { try await Task.sleep(until: instant, clock: .continuous) } catch { return }
                await self?.expireWaiter(id)
            }
        }
        defer { expiry?.cancel() }
        if let deadline, deadline <= .now { throw AdmissionError.deadlineExceeded }
        return try await withTaskCancellationHandler {
            let permit = try await withCheckedThrowingContinuation { continuation in
                // Registration and enqueue do not suspend this actor. A change
                // callback can therefore only run after this waiter exists.
                let priority = demand?.observe(id) { [weak self] priority in
                    Task { await self?.promoteWaiter(id, to: priority) }
                }
                let context = priority.map { context.promoting(to: $0) } ?? context
                dispatch()
                // Allow direct admission when no earlier waiter can use this slot.
                if canAdmitDirectly(context) && eligible(context) {
                    continuation.resume(returning: grant(id, context))
                } else if !hasWaitingCapacity(for: context) {
                    continuation.resume(throwing: AdmissionError.overloaded)
                } else {
                    let observation = V2ResourceTransferWaitScope.context?.begin(waitingReason(context))
                    waiters.append(.init(id: id, context: context, enqueuedAt: monotonicNow(), continuation: continuation, observation: observation)); dispatch()
                }
            }
            if Task.isCancelled { _ = release(permit); throw CancellationError() }
            if let deadline, deadline <= .now { _ = release(permit); throw AdmissionError.deadlineExceeded }
            return permit
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    /// The operation must return only after its underlying I/O has terminated.
    /// Cancellation never releases a physical slot while the operation is still draining.
    public func withPermit<T: Sendable>(_ context: V2NetworkWorkContext, deadline: ContinuousClock.Instant? = nil,
        operation: @Sendable (V2RequestPermit) async throws -> T) async throws -> T {
        let permit = try await acquire(context, deadline: deadline)
        do { let result = try await operation(permit); _ = release(permit); return result }
        catch { _ = release(permit); throw error }
    }
    @discardableResult public func release(_ permit: V2RequestPermit) -> Bool {
        guard permit.schedulerID == identity, active.removeValue(forKey: permit.id) != nil else { return false }
        if let adoptedID = adoptedTransfers.first(where: { $0.value == permit.id })?.key {
            adoptedTransfers.removeValue(forKey: adoptedID)
        }
        dispatch()
        if active.isEmpty { let drains = drainWaiters; drainWaiters.removeAll(); for waiter in drains { waiter.resume() } }
        return true
    }
    /// Stops new work and rejects queued work. The account owner cancels active transports,
    /// then this method waits for their explicit release after actual termination.
    public func beginClose() {
        closed = true
        admissionWake?.cancel(); admissionWake = nil
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.observation?.end(); waiter.continuation.resume(throwing: AdmissionError.closed) }
    }
    public func closeAndDrain() async {
        beginClose()
        if !active.isEmpty { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    private func expireWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.observation?.end(); waiter.continuation.resume(throwing: AdmissionError.deadlineExceeded); dispatch()
    }
    private func promoteWaiter(_ id: UUID, to priority: V2NetworkWorkPriority) {
        guard !closed, let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters[index].context = waiters[index].context.promoting(to: priority)
        dispatch()
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.observation?.end(); waiter.continuation.resume(throwing: CancellationError()); dispatch()
    }
    private func hasWaitingCapacity(for context: V2NetworkWorkContext) -> Bool {
        // Reserved execution slots alone are insufficient when a control request
        // must wait behind another control request during a full ordinary backlog.
        // Keep both queues bounded, without allowing ordinary work to borrow the
        // capacity needed to finish authentication and acknowledgement exchanges.
        switch context.kind {
        case .authentication: return waiters.filter { $0.context.kind == .authentication }.count < configuration.controlWaiterLimit
        case .ordinary: return waiters.filter { $0.context.kind == .ordinary }.count < configuration.waiterLimit
        case .byteTransfer: return waiters.filter { $0.context.kind.byteDirection != nil }.count < configuration.byteTransferWaiterLimit
        }
    }
    private func canAdmitDirectly(_ context: V2NetworkWorkContext) -> Bool {
        if let key = context.orderingKey, waiters.contains(where: { $0.context.orderingKey == key }) { return false }
        return !waiters.contains { prior in
            let samePool = prior.context.kind == context.kind || (prior.context.kind.byteDirection != nil && context.kind.byteDirection != nil)
            return samePool && eligible(prior.context)
        }
    }
    private func eligible(_ context: V2NetworkWorkContext) -> Bool {
        if admissionNotBefore(context) > monotonicNow() { return false }
        if let key = context.orderingKey, active.values.contains(where: { $0.context.orderingKey == key }) { return false }
        let sameKind = active.values.filter { $0.context.kind == context.kind }
        let serviceDegraded = degradedServices.contains(context.service)
        switch context.kind {
        case .authentication: return sameKind.count < configuration.authenticationLimit
        case .byteTransfer(let direction):
            let bytes = active.values.filter { $0.context.kind.byteDirection != nil }
            let totalLimit = (degraded || serviceDegraded) ? min(1, configuration.byteTransferLimit) : configuration.byteTransferLimit
            let directionalLimit = direction == .upload ? configuration.uploadTransferLimit : configuration.downloadTransferLimit
            guard bytes.count < totalLimit, sameKind.count < directionalLimit else { return false }
            guard bytes.filter({ $0.context.kind.byteDirection == .upload }).count <= configuration.uploadTransferLimit,
                  bytes.filter({ $0.context.kind.byteDirection == .download }).count <= configuration.downloadTransferLimit else { return false }
            if context.priority == .background {
                // Automatic prefetch cannot borrow the final user/recovery
                // slot. A one-slot configuration still permits forward progress.
                let totalBackground = max(1, totalLimit - min(configuration.interactiveByteReserve, totalLimit - 1))
                let directionBackground = max(1, directionalLimit - min(configuration.interactiveByteReserve, directionalLimit - 1))
                return bytes.filter { $0.context.priority == .background }.count < totalBackground
                    && sameKind.filter { $0.context.priority == .background }.count < directionBackground
            }
            return true
        case .ordinary:
            return sameKind.count < (degraded ? min(3, configuration.ordinaryLimit) : configuration.ordinaryLimit)
                && sameKind.filter { $0.context.service == context.service }.count < (serviceDegraded ? min(3, configuration.serviceLimit) : configuration.serviceLimit)
        }
    }
    private func grant(_ id: UUID, _ context: V2NetworkWorkContext) -> V2RequestPermit {
        if context.isRetry && context.kind != .authentication {
            precondition(serviceAdmission[context.service]!.retries.consume(now: monotonicNow()))
        }
        let permit = V2RequestPermit(schedulerID: identity, id: id, context: context); active[id] = permit; return permit
    }
    private func admissionNotBefore(_ context: V2NetworkWorkContext) -> TimeInterval {
        let now = monotonicNow()
        guard context.kind != .authentication, var state = serviceAdmission[context.service] else { return now }
        let due = max(state.cooldownUntil, context.isRetry ? state.retries.nextAvailableAt(now: now) : now)
        serviceAdmission[context.service] = state
        return due
    }
    private func scheduleAdmissionWake() {
        admissionWake?.cancel(); admissionWake = nil
        let now = monotonicNow()
        let due = waiters.map { admissionNotBefore($0.context) }.filter { $0 > now }.min()
        guard let due else { return }
        admissionWake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, due - now))) }
            catch { return }
            await self?.dispatch()
        }
    }
    private func waitingReason(_ context: V2NetworkWorkContext) -> V2ResourceTransferWaitingReason {
        if admissionNotBefore(context) > monotonicNow() { return .serviceCooldown }
        return context.kind.byteDirection != nil ? .transferSlot : .requestSlot
    }
    private func dispatch() {
        guard !closed else { return }
        for waiter in waiters { waiter.observation?.update(waitingReason(waiter.context)) }
        while true {
            var selected: Int?
            // Aging changes selection, never capacity or a prefetch's right to
            // borrow an interactive reservation. FIFO remains authoritative
            // within an ordering key, even when only the follower is eligible.
            selected = waiters.indices.first { index in
                let candidate = waiters[index]
                guard candidate.context.kind.byteDirection != nil,
                      monotonicNow() - candidate.enqueuedAt >= configuration.byteTransferAgingInterval,
                      eligible(candidate.context) else { return false }
                if let key = candidate.context.orderingKey,
                   waiters[..<index].contains(where: { $0.context.orderingKey == key }) { return false }
                return true
            }
            for offset in 0..<wheel.count where selected == nil {
                let position = (cursor + offset) % wheel.count
                if let index = waiters.indices.first(where: { index in
                    let candidate = waiters[index]
                    guard candidate.context.priority == wheel[position], eligible(candidate.context) else { return false }
                    if let key = candidate.context.orderingKey,
                       waiters[..<index].contains(where: { $0.context.orderingKey == key }) { return false }
                    return true
                }) { selected = index; cursor = (position + 1) % wheel.count; break }
            }
            guard let selected else { scheduleAdmissionWake(); return }
            let waiter = waiters.remove(at: selected)
            waiter.observation?.end()
            waiter.continuation.resume(returning: grant(waiter.id, waiter.context))
        }
    }
}
