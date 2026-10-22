import Foundation
import IMV2Core

public protocol V2ResourceUploadControlling: Sendable {
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession
    func status(_ locator: V2ResourceUploadLocator) async throws -> V2ResourceUploadSession
    func target(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan?
    func finalize(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession
    func cancel(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession
}

public protocol V2BackgroundResourceUploadControlling: V2ResourceUploadControlling {
    func backgroundTarget(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan?
}

public protocol V2ResourcePlanExecuting: Sendable {
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws
}

/// Account-owned foreground engine. The journal is the only recovery source;
/// short-lived targets are always obtained anew and never encoded into a row.
public actor V2ResourceTransferEngine {
    private let store: GRDBV2LocalSyncStore
    private let control: any V2ResourceUploadControlling
    private let executor: any V2ResourcePlanExecuting
    private let directory: URL
    private let capabilities: V2ResourceCapabilitiesCache?
    private var background: V2BackgroundTransferCoordinator?
    public func attachBackground(_ coordinator: V2BackgroundTransferCoordinator) async throws {
        try await coordinator.initialize()
        guard !closed, background == nil else { throw V2BackgroundTransferError.closed }
        background = coordinator
    }
    private var closed = false
    private let ownerID = UUID()
    private var recovered = false
    private let now: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double
    private let operations = V2ResourceOperationScope()
    private var flights: [UUID: V2SharedOperation<V2ResourceTransferJob>] = [:]

    public init(store: GRDBV2LocalSyncStore, control: any V2ResourceUploadControlling, executor: any V2ResourcePlanExecuting, directory: URL, capabilities: V2ResourceCapabilitiesCache? = nil, now: @escaping @Sendable () -> Date = Date.init, randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.store = store; self.control = control; self.executor = executor; self.directory = directory
        self.capabilities = capabilities
        self.now = now; self.randomUnit = randomUnit
    }

    public func prepare(id: UUID, request: V2ResourceUploadRequest) async throws -> V2ResourceTransferJob {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performPrepare(id: id, request: request) }
    }

    private func performPrepare(id: UUID, request: V2ResourceUploadRequest) async throws -> V2ResourceTransferJob {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        // A persisted operation may already exist at an older backend after a lost
        // response. Its recovery must not be re-admitted against the new default.
        if try await store.resourceTransfer(id: id) == nil {
            try await capabilities?.validateNewUpload(request)
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return try await store.prepareResourceTransfer(id: id, request: request, localFileToken: id.uuidString)
    }

    public func prepareSend(_ intent: V2SendIntent, resources: [V2ResourcePreparedUpload]) async throws {
        guard !closed else { throw CancellationError() }
        try await operations.run {
            for resource in resources {
                try Task.checkCancellation()
                if try await self.store.resourceTransfer(id: resource.id) == nil {
                    try await self.capabilities?.validateNewUpload(resource.request)
                }
            }
            try Task.checkCancellation()
            try await self.store.freezeSendIntent(intent, resources: resources)
        }
    }

    public func refreshCapabilitiesIfNeeded() async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performRefreshCapabilities() }
    }

    private func performRefreshCapabilities() async throws {
        guard !closed else { throw CancellationError() }
        try await capabilities?.refreshIfNeeded()
    }

    public func resume(id: UUID) async throws -> V2ResourceTransferJob {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let flight = flights[id] { return try await flight.value }
        guard flights.count < 2 else { throw V2ClientMediaTransferError.serverStatus(429) }
        // The account owns the work; a disappearing page only cancels its waiter.
        let flight = V2SharedOperation { try await self.perform(id: id) }
        flights[id] = flight
        return try await flight.value
    }

    public func cancel(id: UUID) async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performCancel(id: id) }
    }

    private func performCancel(id: UUID) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard try await store.requestResourceCancellation(id: id) != nil else { return }
        if let flight = flights[id] { flight.cancel(); _ = await flight.result }
        try await background?.cancel(jobID: id)
    }

    public func releaseAcceptedStaging(id: UUID) async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performReleaseAcceptedStaging(id: id) }
    }

    private func performReleaseAcceptedStaging(id: UUID) async throws {
        guard !closed, flights[id] == nil,
              let token = try await store.claimReleasableResourceFileToken(id: id), UUID(uuidString: token) != nil else { return }
        guard !closed else { throw CancellationError() }
        let file = directory.appendingPathComponent(token)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try await store.confirmResourceStagingReleased(id: id)
    }

    public func releaseAcceptedStaging() async throws {
        guard !closed else { throw CancellationError() }
        return try await operations.run { try await self.performReleaseAcceptedStaging() }
    }

    private func performReleaseAcceptedStaging() async throws {
        guard !closed else { throw CancellationError() }
        for id in try await store.releasableResourceJobs() {
            try Task.checkCancellation()
            try await performReleaseAcceptedStaging(id: id)
        }
    }

    public func close() async {
        closed = true
        async let drainOperations: Void = operations.close()
        await capabilities?.close()
        let running = Array(flights.values)
        for flight in running { flight.cancel() }
        for flight in running { _ = await flight.result }
        flights.removeAll()
        await drainOperations
        await background?.close()
    }

    /// Account activity: durable due dates and database updates drive one short
    /// step per job. No request or provider target survives a step boundary.
    public func runRecovery() async throws {
        guard !closed else { throw CancellationError() }
        try await recoverOnceIfNeeded()
        do {
            try await V2CommandRetryScheduler(schedule: store.resourceWorkSchedule(), flush: {
                for id in try await self.store.dueResourceTransfers(now: self.now()) {
                    do { _ = try await self.resume(id: id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { /* The step recorded its retry or needs-attention state. */ }
                }
            }).run()
            try Task.checkCancellation()
        } catch {
            // A scheduler waiter cancels independently of its shared step.
            // The account activity must explicitly cancel and drain that I/O.
            if Task.isCancelled {
                let running = Array(flights.values)
                for flight in running { flight.cancel() }
                for flight in running { _ = await flight.result }
            }
            throw error
        }
    }

    private func recoverOnceIfNeeded() async throws {
        guard !recovered else { return }
        try await store.recoverResourceExecutions(owner: ownerID)
        recovered = true
    }

    private func perform(id: UUID) async throws -> V2ResourceTransferJob {
        defer { flights.removeValue(forKey: id) }
        try await recoverOnceIfNeeded()
        guard let job = try await store.claimResourceStep(id: id, owner: ownerID, now: now()) else { return try await requireJob(id) }
        do {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let seconds = max(0, (job.roundDeadline ?? now()).timeIntervalSince(now()))
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            try await V2HTTPRequestDeadline.$current.withValue(deadline) {
                try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .recovery, isRetry: job.lastError != nil && job.actionAttempts > 1)) {
                    try await self.executeAction(job)
                }
            }
            return try await requireJob(id)
        } catch {
            if error is CancellationError || Task.isCancelled || closed {
                try await store.failResourceStep(id: id, owner: ownerID, code: "cancelled", retryAt: nil, cancellation: true)
                throw CancellationError()
            }
            let http = error as? V2HTTPFailure
            let retryable: Bool
            if let http {
                switch http.kind {
                case .transport, .deadlineExceeded: retryable = true
                case .httpStatus:
                    // Object-provider denial may mean an expired signature. The
                    // persisted status action rechecks authority before a new plan;
                    // control-plane 403 remains terminal for this recovery round.
                    let providerSignatureDenied = job.nextAction == .upload && http.service == "mediaProvider" && [401,403].contains(http.statusCode ?? 0)
                    retryable = providerSignatureDenied || http.statusCode == 401 || http.statusCode == 408 || http.statusCode == 429 || (http.statusCode ?? 0) >= 500
                default: retryable = false
                }
            } else { retryable = error is URLError || (error as? V2ClientMediaTransferError) == .authorizationUnavailable || (error as? V2ClientMediaTransferError) == .targetExpired }
            let policy = V2NetworkWorkPolicy.commandRecovery
            let next = retryable ? policy.nextAttempt(now: now(), startedAt: (job.roundDeadline ?? now()).addingTimeInterval(-policy.totalBudget), attemptsCompleted: job.actionAttempts, randomUnit: randomUnit(), serverRetryNotBefore: http?.retryAfter) : nil
            try await store.failResourceStep(id: id, owner: ownerID, code: retryable ? "transport" : "needsAttention", retryAt: next, serverRetryNotBefore: http?.retryAfter)
            throw error
        }
    }

    private func executeAction(_ job: V2ResourceTransferJob) async throws {
        let id = job.id
            switch job.nextAction {
            case .awaitingBackground:
                throw V2BackgroundTransferError.mappingConflict
            case .create:
                let session = try await control.create(job.request)
                try await save(session, id: id)
                try await finish(session: session, job: job)
            case .status:
                guard let saved = job.session else { throw V2ResourceJournalError.invalidRecord }
                let session = try await control.status(saved.locator)
                try await save(session, id: id)
                try await finish(session: session, job: job)
            case .upload:
                guard let session = job.session else { throw V2ResourceJournalError.invalidRecord }
                let file = directory.appendingPathComponent(job.localFileToken)
                guard FileManager.default.fileExists(atPath: file.path) else { throw V2ClientMediaTransferError.fileSystemFailure }
                let digest = try V2ResourceFileDigest.sha256(fileURL: file, expectedByteCount: job.request.byteCount)
                guard digest == job.request.checksum.value else { throw V2ClientMediaTransferError.byteCountMismatch }
                let target: V2ResourceTransferPlan?
                if background != nil, case .messageAttachment = job.request.usage,
                   let controller = control as? any V2BackgroundResourceUploadControlling {
                    try await capabilities?.refreshIfNeeded()
                    if await capabilities?.allowsBackground() == true { target = try await controller.backgroundTarget(session) }
                    else { target = try await control.target(session) }
                } else { target = try await control.target(session) }
                guard let plan = target else {
                    try Task.checkCancellation()
                    guard !closed else { throw CancellationError() }
                    guard job.request.clientModes.contains(.httpPartPut) else { throw V2ClientMediaTransferError.invalidTarget }
                    var confirmedBytes: Int64 = 0
                    for part in session.confirmedParts {
                        guard part.byteCount <= job.request.byteCount - confirmedBytes else { throw V2ClientMediaTransferError.invalidTarget }
                        confirmedBytes += part.byteCount
                    }
                    guard confirmedBytes == job.request.byteCount else { throw V2ClientMediaTransferError.invalidTarget }
                    try await store.finishResourceStep(id: id, owner: ownerID, next: .finalize, retryAt: now())
                    return
                }
                try Task.checkCancellation()
                if plan.backgroundAuthorization != nil {
                    guard let background else { throw V2BackgroundTransferError.unsupported }
                    try await background.enqueue(job: job, resourceOwner: ownerID, plan: plan, source: file)
                    return
                }
                do {
                    try await executor.upload(fileURL: file, plan: plan)
                } catch let failure as V2HTTPFailure {
                    // An immutable single-object upload may already exist after a
                    // lost success response. Only the control plane can verify its
                    // size and digest; a conflict itself is never proof of success.
                    guard plan.mode == .httpPut, failure.kind == .httpStatus,
                          failure.service == "mediaProvider", failure.statusCode == 409 else { throw failure }
                }
                try Task.checkCancellation()
                try await store.finishResourceStep(id: id, owner: ownerID, next: plan.mode == .httpPartPut ? .status : .finalize, retryAt: now())
            case .finalize:
                guard let session = job.session else { throw V2ResourceJournalError.invalidRecord }
                let result = try await control.finalize(session)
                try await save(result, id: id)
                try await finish(session: result, job: job)
            case .cancel:
                let session: V2ResourceUploadSession
                if let saved = job.session { session = try await control.status(saved.locator) }
                else { session = try await control.create(job.request) }
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                let result = session.state == .completed ? session : try await control.cancel(session)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                try await store.confirmResourceCancellation(id: id, session: result)
                try await store.finishResourceStep(id: id, owner: ownerID, next: .cancel, retryAt: now())
            }
    }

    private func finish(session: V2ResourceUploadSession, job: V2ResourceTransferJob) async throws {
        let processing = session.resourceState != .ready && (session.state == .finalizing || session.state == .completed)
        if processing && (job.pollAttempts >= 60 || session.expiresAt <= now()) {
            try await store.failResourceStep(id: job.id, owner: ownerID, code: "processingBudgetExhausted", retryAt: nil)
            return
        }
        let next: V2ResourceTransferJob.Action = session.state == .created || session.state == .uploading ? .upload : .status
        let delay = processing ? V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: job.pollAttempts, serverDelay: session.retryNotBefore?.timeIntervalSince(now())) : max(0, session.retryNotBefore?.timeIntervalSince(now()) ?? 0)
        try await store.finishResourceStep(id: job.id, owner: ownerID, next: next, retryAt: now().addingTimeInterval(delay), processingPoll: processing, preserveBudget: !processing && job.lastError != nil && next == .upload)
    }

    private func save(_ session: V2ResourceUploadSession, id: UUID) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.saveResourceSession(session, for: id)
    }
    private func requireJob(_ id: UUID) async throws -> V2ResourceTransferJob {
        guard let result = try await store.resourceTransfer(id: id) else { throw V2ResourceJournalError.invalidRecord }
        return result
    }
}
