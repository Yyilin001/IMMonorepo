import Foundation
import IMV2Core

public protocol V2ResourceUploadControlling: Sendable {
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession
    func status(_ locator: V2ResourceUploadLocator) async throws -> V2ResourceUploadSession
    func target(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan
    func finalize(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession
    func cancel(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession
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
    private var closed = false
    private let operations = V2ResourceOperationScope()
    private var flights: [UUID: V2SharedOperation<V2ResourceTransferJob>] = [:]

    public init(store: GRDBV2LocalSyncStore, control: any V2ResourceUploadControlling, executor: any V2ResourcePlanExecuting, directory: URL, capabilities: V2ResourceCapabilitiesCache? = nil) {
        self.store = store; self.control = control; self.executor = executor; self.directory = directory
        self.capabilities = capabilities
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
        guard let job = try await store.requestResourceCancellation(id: id) else { return }
        if let flight = flights[id] { flight.cancel(); _ = await flight.result }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let session: V2ResourceUploadSession
        if let saved = job.session { session = try await control.status(saved.locator) }
        else { session = try await control.create(job.request) }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        // Completion won the race. The cancelled intent will never bind it;
        // server retention owns this unbound resource from here.
        let result = session.state == .completed ? session : try await control.cancel(session)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        try await store.confirmResourceCancellation(id: id, session: result)
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
    }

    private func perform(id: UUID) async throws -> V2ResourceTransferJob {
        defer { flights.removeValue(forKey: id) }
        do {
            guard let job = try await store.resourceTransfer(id: id) else { throw V2ResourceJournalError.invalidRecord }
            guard !job.cancellationRequested, ![.cancelled, .expired, .rejected].contains(job.stage) else { throw V2ClientMediaTransferError.mediaRejected }
            try Task.checkCancellation()
            // Creation replay is safe: the stable request is persisted before I/O.
            var session: V2ResourceUploadSession
            if let saved = job.session { session = try await control.status(saved.locator) }
            else { session = try await control.create(job.request) }
            try await save(session, id: id)
            if session.resourceState == .ready { return try await requireJob(id) }
            guard session.state != .cancelled, session.state != .expired, session.state != .failed else { throw V2ClientMediaTransferError.mediaRejected }
            if session.state == .created || session.state == .uploading {
                let file = directory.appendingPathComponent(job.localFileToken)
                guard FileManager.default.fileExists(atPath: file.path) else { throw V2ClientMediaTransferError.fileSystemFailure }
                let digest = try V2ResourceFileDigest.sha256(fileURL: file, expectedByteCount: job.request.byteCount)
                guard digest == job.request.checksum.value else { throw V2ClientMediaTransferError.byteCountMismatch }
                let plan = try await control.target(session)
                try Task.checkCancellation()
                try await executor.upload(fileURL: file, plan: plan)
                try Task.checkCancellation()
                session = try await control.finalize(session)
                try await save(session, id: id)
            }
            for _ in 0..<60 {
                try Task.checkCancellation()
                if session.resourceState == .ready { return try await requireJob(id) }
                guard session.resourceState != .rejected, session.state != .failed, session.state != .cancelled, session.state != .expired else { throw V2ClientMediaTransferError.mediaRejected }
                let delay = max(1, min(60, session.retryNotBefore?.timeIntervalSinceNow ?? 1))
                try await Task.sleep(for: .seconds(delay))
                session = try await control.status(session.locator)
                try await save(session, id: id)
            }
            throw V2ClientMediaTransferError.scanPending
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled || closed { throw CancellationError() }
            let code: String
            switch error {
            case V2ClientMediaTransferError.scanPending: code = "processing"
            case V2ClientMediaTransferError.fileSystemFailure: code = "fileUnavailable"
            case V2ClientMediaTransferError.mediaRejected: code = "rejected"
            default: code = "network"
            }
            try await store.pauseResourceTransfer(id: id, code: code, retryAt: Date().addingTimeInterval(5))
            throw error
        }
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
