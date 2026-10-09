import CryptoKit
import Foundation
import IMV2Core

/// A freshly authorized, verified staging file. It is not a presentation lease.
public struct V2BackgroundDownloadedFile: Sendable {
    public let fileURL: URL
    fileprivate let ownerID: UUID
    fileprivate let jobID: UUID
    fileprivate let mappingID: UUID
}

/// Account-owned OS downloads. UI cancellation detaches its waiter; explicit
/// withdrawal/logout cancels and drains the physical task before releasing I/O.
public actor V2BackgroundDownloadCoordinator {
    public nonisolated let sessionID: UUID
    private let ownerID = UUID()
    private let accountID: UserID
    private let store: GRDBV2LocalSyncStore
    private let scheduler: V2AccountWorkScheduler
    private let resolver: any V2ClientMediaDownloadTargetResolver
    private let driver: any V2BackgroundDownloadSessionDriving
    private let inbox: V2BackgroundResultInbox
    private let operations = V2ResourceOperationScope(limit: 4)
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var permits: [UUID: V2RequestPermit] = [:]
    private var unmappedTaskIdentities: [Int: UUID] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var creating: Set<UUID> = []
    private var initialTargets: [UUID: V2ClientMediaTransferTarget] = [:]
    private var waiters: [UUID: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var initialization: Task<Void, any Error>?
    private var reconciliation: Task<Void, any Error>?
    private var reconciliationDirty = false
    private var timer: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var initialized = false
    private var closed = false

    public init(sessionID: UUID, accountID: UserID, store: GRDBV2LocalSyncStore,
                scheduler: V2AccountWorkScheduler, resolver: any V2ClientMediaDownloadTargetResolver,
                driver: any V2BackgroundDownloadSessionDriving, root: URL,
                protectionWriter: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        self.sessionID = sessionID; self.accountID = accountID; self.store = store
        self.scheduler = scheduler; self.resolver = resolver; self.driver = driver
        inbox = try .init(root: root.appendingPathComponent("downloads", isDirectory: true),
                          sessionID: sessionID, protectionWriter: protectionWriter)
    }

    #if os(iOS)
    public nonisolated static func native(accountID: UserID, store: GRDBV2LocalSyncStore,
        scheduler: V2AccountWorkScheduler, resolver: any V2ClientMediaDownloadTargetResolver) async throws -> V2BackgroundDownloadCoordinator {
        let id = try await store.backgroundSessionID(), root = try V2BackgroundTransferCoordinator.defaultRoot()
        return try .init(sessionID: id, accountID: accountID, store: store, scheduler: scheduler,
            resolver: resolver, driver: V2NativeBackgroundSession.sharedDownload(sessionID: id, root: root), root: root)
    }
    #endif

    public func initialize() async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        if initialized { return }
        if let initialization { try await initialization.value; return }
        let work = Task {
            await self.driver.installWake { [weak self] in await self?.wake() }
            try await self.reconcile()
        }
        initialization = work
        do { try await work.value; initialized = true; initialization = nil }
        catch { initialization = nil; throw error }
    }

    public func run() async throws {
        do {
            try await initialize()
            for await _ in wakes.stream {
                try Task.checkCancellation()
                do { try await reconcile() }
                catch {
                    if let protection = driver as? any V2BackgroundProtectedDataChecking,
                       !(await protection.protectedDataAvailable()) { continue }
                    throw error
                }
            }
            try Task.checkCancellation()
        } catch { await close(); throw error }
    }

    public func download(mediaID: MediaID, message: V2MediaMessageLocation?,
                         initialTarget: V2ClientMediaTransferTarget) async throws -> V2BackgroundDownloadedFile {
        try await operations.run { try await self.performDownload(mediaID: mediaID, message: message, initialTarget: initialTarget) }
    }

    private func performDownload(mediaID: MediaID, message: V2MediaMessageLocation?,
                                 initialTarget: V2ClientMediaTransferTarget) async throws -> V2BackgroundDownloadedFile {
        _ = try V2BackgroundDownloadRequest.make(target: initialTarget)
        try await initialize()
        guard !closed else { throw V2BackgroundTransferError.closed }
        let job = try await store.beginBackgroundDownload(id: UUID(), mediaID: mediaID, message: message,
                                                         accountID: accountID, adoptMatching: true)
        if case .paused = job.state { throw V2BackgroundTransferError.mappingConflict }
        if case .preparing = job.state { initialTargets[job.id] = initialTarget }
        wake()
        try await reconcile()
        let task = try await waitForDownload(jobID: job.id)
        // Download completion does not preserve a permission decision. This
        // fresh request observes withdrawal, member/device/account revocation.
        let fresh: V2ClientMediaTransferTarget
        do { fresh = try await resolver.resolveDownloadTarget(mediaID: mediaID, message: message) }
        catch is CancellationError { throw CancellationError() }
        catch { try? await cancel(mediaID: mediaID); throw error }
        try Task.checkCancellation()
        guard !closed, fresh.expiresAt > Date(), fresh.checksum == task.checksum,
              fresh.expectedByteCount == task.expectedByteCount,
              try await currentJob(job.id)?.state == .downloaded(task)
        else { try? await cancel(mediaID: mediaID); throw V2BackgroundTransferError.invalidAuthorization }
        let file = fileURL(task.id)
        try await Self.verify(file: file, task: task)
        try Task.checkCancellation()
        guard !closed, fresh.expiresAt > Date(), try await currentJob(job.id)?.state == .downloaded(task)
        else { throw CancellationError() }
        return .init(fileURL: file, ownerID: ownerID, jobID: job.id, mappingID: task.id)
    }

    /// Call only after moving the verified file into the account's protected cache.
    public func didPublish(_ file: V2BackgroundDownloadedFile) async throws {
        guard file.ownerID == ownerID, !closed else { throw V2BackgroundTransferError.mappingConflict }
        guard !FileManager.default.fileExists(atPath: file.fileURL.path) else { throw V2BackgroundTransferError.mappingConflict }
        if try await store.retireBackgroundDownload(id: file.jobID, mappingID: file.mappingID, accountID: accountID) {
            try inbox.remove(file.mappingID)
        }
        notify(file.jobID)
    }

    private func waitForDownload(jobID: UUID) async throws -> V2BackgroundDownloadTask {
        let id = UUID(), pulse = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[jobID, default: [:]][id] = pulse.continuation
        defer { waiters[jobID]?[id] = nil; if waiters[jobID]?.isEmpty == true { waiters[jobID] = nil }; pulse.continuation.finish() }
        var iterator = pulse.stream.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            guard !closed, let job = try await currentJob(jobID) else { throw CancellationError() }
            switch job.state {
            case .downloaded(let task): return task
            case .cancelled: throw CancellationError()
            case .paused: throw V2BackgroundTransferError.mappingConflict
            default: break
            }
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    private func currentJob(_ id: UUID) async throws -> V2BackgroundDownloadJob? {
        try await store.backgroundDownloads(accountID: accountID).first { $0.id == id }
    }
    private func fileURL(_ id: UUID) -> URL {
        inbox.directory.appendingPathComponent("files", isDirectory: true).appendingPathComponent(id.uuidString)
    }
    private func wake() { wakes.continuation.yield(()) }
    private func notify(_ id: UUID) { if let values = waiters[id] { for waiter in values.values { waiter.yield(()) } } }
    private func release(_ id: UUID) async { if let permit = permits.removeValue(forKey: id) { _ = await scheduler.release(permit) } }

    private func reconcile() async throws {
        if let reconciliation { reconciliationDirty = true; try await reconciliation.value; return }
        let work = Task {
            repeat {
                self.reconciliationDirty = false
                try await self.performReconciliation()
            } while self.reconciliationDirty && !self.closed
        }
        reconciliation = work
        do { try await work.value; reconciliation = nil }
        catch { reconciliation = nil; throw error }
    }

    private func performReconciliation() async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        let actual = await driver.tasks()
        guard actual.count <= 16 else { await driver.cancelAndDrain(actual.map(\.identifier)); throw V2BackgroundTransferError.capacityExceeded }
        // Account for every physical task before querying protected business state.
        var identities: [Int: UUID] = [:]
        for task in actual {
            let id = task.mappingID ?? unmappedTaskIdentities[task.identifier] ?? UUID()
            if task.mappingID == nil { unmappedTaskIdentities[task.identifier] = id }
            identities[task.identifier] = id
            if permits[id] == nil { permits[id] = try await scheduler.adoptExistingByteTransfer(id: id,
                context: .init(service: "mediaProvider", priority: .background, kind: .byteTransfer)) }
        }
        for (identifier, id) in unmappedTaskIdentities where !actual.contains(where: { $0.identifier == identifier }) {
            await release(id); unmappedTaskIdentities[identifier] = nil
        }
        if let protection = driver as? any V2BackgroundProtectedDataChecking,
           !(await protection.protectedDataAvailable()) { throw V2BackgroundTransferError.protectedDataUnavailable }
        let jobs = try await store.backgroundDownloads(accountID: accountID)
        let mappings = Dictionary(jobs.compactMap { job -> (UUID, V2BackgroundDownloadTask)? in
            switch job.state {
            case .transferring(let task), .downloaded(let task): (task.id, task)
            case .cancelled(let task): task.map { ($0.id, $0) }
            default: nil
            }
        }, uniquingKeysWith: { first, _ in first })
        let orphans = actual.filter { task in
            guard let id = task.mappingID else { return true }
            if creating.contains(id) { return false }
            return mappings[id]?.identifier != task.identifier || mappings[id]?.sessionID != sessionID
        }
        if !orphans.isEmpty {
            await driver.cancelAndDrain(orphans.map(\.identifier))
            for task in orphans { if let id = identities[task.identifier] { await release(id) } }
        }
        let receipts = try inbox.results()
        let byID = Dictionary(receipts.map { ($0.mappingID, $0) }, uniquingKeysWith: { _, last in last })
        var nextWake = Date().addingTimeInterval(900)
        var needsTimer = false
        for job in jobs {
            try Task.checkCancellation()
            guard !closed else { throw V2BackgroundTransferError.closed }
            switch job.state {
            case .transferring(let task):
                let active = actual.first { $0.mappingID == task.id && $0.identifier == task.identifier }
                if let active {
                    if task.expiresAt <= Date() {
                        await driver.cancelAndDrain([active.identifier]); wake()
                    } else if byID[task.id] != nil {
                        nextWake = min(nextWake, Date().addingTimeInterval(0.2)); needsTimer = true
                    } else {
                        if active.suspended { try await driver.resume(active.identifier) }
                        nextWake = min(nextWake, task.expiresAt); needsTimer = true
                    }
                } else {
                    let result = byID[task.id]
                    var success = result.map { $0.taskIdentifier == task.identifier && $0.errorCode == nil && $0.statusCode == 200
                        && $0.receivedBytes == task.expectedByteCount && $0.originDigest == task.originDigest } ?? false
                    if success {
                        do { try await Self.verify(file: fileURL(task.id), task: task) }
                        catch { success = false }
                    }
                    _ = try await store.finishBackgroundDownloadTask(id: job.id, mappingID: task.id, sessionID: task.sessionID,
                        identifier: task.identifier, success: success, accountID: accountID)
                    try inbox.remove(task.id)
                    if !success { try? FileManager.default.removeItem(at: fileURL(task.id)); wake() }
                    await release(task.id); notify(job.id)
                }
            case .preparing:
                let retry = Date(timeIntervalSince1970: Double(job.retryAtMilliseconds) / 1_000)
                if retry > Date() { nextWake = min(nextWake, retry); needsTimer = true }
                else if preparations[job.id] == nil {
                    preparations[job.id] = Task { await self.prepare(job) }
                }
            case .cancelled(let task):
                if let task {
                    await driver.cancelAndDrain(actual.filter { $0.mappingID == task.id }.map(\.identifier))
                    await release(task.id); try inbox.remove(task.id)
                    try? FileManager.default.removeItem(at: fileURL(task.id))
                }
                _ = try await store.retireBackgroundDownload(id: job.id, mappingID: task?.id, accountID: accountID)
                notify(job.id)
            case .downloaded, .paused: notify(job.id)
            }
        }
        for receipt in receipts where mappings[receipt.mappingID] == nil && !creating.contains(receipt.mappingID) {
            try inbox.remove(receipt.mappingID); try? FileManager.default.removeItem(at: fileURL(receipt.mappingID))
        }
        timer?.cancel(); timer = nil
        if needsTimer {
            let delay = max(0.05, nextWake.timeIntervalSinceNow)
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)); await self?.wake() } catch { }
            }
        }
    }

    private func prepare(_ job: V2BackgroundDownloadJob) async {
        defer { preparations[job.id] = nil; initialTargets[job.id] = nil; wake() }
        let mappingID = UUID()
        var taskIdentifier: Int?, installed = false
        do {
            let target: V2ClientMediaTransferTarget
            if let initial = initialTargets.removeValue(forKey: job.id), initial.expiresAt > Date() { target = initial }
            else { target = try await resolver.resolveDownloadTarget(mediaID: job.mediaID, message: job.message) }
            _ = try V2BackgroundDownloadRequest.make(target: target)
            guard let grant = target.backgroundDownloadAuthorization, let origin = V2BackgroundResultInbox.originDigest(target.url)
            else { throw V2BackgroundTransferError.invalidAuthorization }
            let permit = try await scheduler.acquire(.init(service: "mediaProvider", priority: .background, kind: .byteTransfer,
                isRetry: job.attemptCount > 0), deadline: .now.advanced(by: .seconds(min(15, target.expiresAt.timeIntervalSinceNow))))
            permits[mappingID] = permit; creating.insert(mappingID)
            try Task.checkCancellation()
            guard !closed, try await currentJob(job.id)?.state == .preparing else { throw CancellationError() }
            let identifier = try await driver.create(target: target, mappingID: mappingID); taskIdentifier = identifier
            let task = try V2BackgroundDownloadTask(id: mappingID, sessionID: sessionID, identifier: identifier,
                grantID: grant.id, expectedByteCount: target.expectedByteCount, checksum: target.checksum,
                originDigest: origin, expiresAtMilliseconds: grant.expiresAtMilliseconds)
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            try await store.installBackgroundDownloadTask(id: job.id, task: task, accountID: accountID); installed = true
            creating.remove(mappingID)
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            try await driver.resume(identifier)
        } catch {
            if let taskIdentifier { await driver.cancelAndDrain([taskIdentifier]) }
            if installed, let taskIdentifier {
                _ = try? await store.finishBackgroundDownloadTask(id: job.id, mappingID: mappingID, sessionID: sessionID,
                    identifier: taskIdentifier, success: false, accountID: accountID)
            } else { try? await store.failBackgroundDownloadPreparation(id: job.id, accountID: accountID) }
            creating.remove(mappingID); await release(mappingID); notify(job.id)
        }
    }

    public func cancel(mediaID: MediaID) async throws {
        guard !closed else { return }
        for job in try await store.backgroundDownloads(accountID: accountID) where job.mediaID == mediaID {
            try await store.cancelBackgroundDownload(id: job.id, accountID: accountID)
            preparations[job.id]?.cancel(); _ = await preparations[job.id]?.result
            notify(job.id)
        }
        try await reconcile()
    }

    public func close() async {
        if let closing { await closing.value; return }
        let work = Task { await self.performClose() }; closing = work; await work.value
    }
    private func performClose() async {
        guard !closed else { return }; closed = true
        timer?.cancel(); initialization?.cancel(); reconciliation?.cancel()
        for values in waiters.values { for waiter in values.values { waiter.finish() } }
        for work in preparations.values { work.cancel() }
        let pending = Array(preparations.values)
        for work in pending { await work.value }
        await operations.close()
        _ = await initialization?.result; _ = await reconciliation?.result
        let actual = await driver.tasks()
        await driver.cancelAndDrain(actual.map(\.identifier))
        if let jobs = try? await store.backgroundDownloads(accountID: accountID) {
            for job in jobs {
                try? await store.cancelBackgroundDownload(id: job.id, accountID: accountID)
                let task: V2BackgroundDownloadTask?
                switch job.state {
                case .transferring(let value), .downloaded(let value): task = value
                case .cancelled(let value): task = value
                default: task = nil
                }
                if let task { try? inbox.remove(task.id); try? FileManager.default.removeItem(at: fileURL(task.id)) }
                _ = try? await store.retireBackgroundDownload(id: job.id, mappingID: task?.id, accountID: accountID)
            }
        }
        for id in Array(permits.keys) { await release(id) }
        wakes.continuation.finish()
        #if os(iOS)
        (driver as? V2NativeBackgroundSession)?.invalidateAfterDrain()
        #endif
    }

    private nonisolated static func verify(file: URL, task: V2BackgroundDownloadTask) async throws {
        // File hashing is blocking I/O and can be large. This owned task is
        // cancelled and drained; it never occupies MainActor or a NIO EventLoop.
        let work = Task.detached(priority: .utility) {
            let facts = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard facts.isRegularFile == true, facts.isSymbolicLink != true, Int64(facts.fileSize ?? -1) == task.expectedByteCount
            else { throw V2ClientMediaTransferError.byteCountMismatch }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var digest = SHA256(), count: Int64 = 0
            while let bytes = try handle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
                try Task.checkCancellation(); count += Int64(bytes.count)
                guard count <= task.expectedByteCount else { throw V2ClientMediaTransferError.byteCountMismatch }
                digest.update(data: bytes)
            }
            guard count == task.expectedByteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == task.checksum.value
            else { throw V2ClientMediaTransferError.checksumMismatch }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
