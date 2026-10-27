import Foundation
import IMV2Core

/// Integrity-verified source only. The cache must freshly authorize every
/// reader after this shared byte operation, before issuing presentation leases.
struct V2BackgroundDownloadedFile: Sendable {
    let reservation: V2ResourceTransferStaging
    var fileURL: URL { reservation.fileURL }
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
    private let now: @Sendable () -> Date
    private let driver: any V2BackgroundDownloadSessionDriving
    private let inbox: V2BackgroundResultInbox
    private let files: V2ResourceFileStore
    private let byteInbox: V2ResourceBackgroundDownloadInbox
    private var ownedReservations: [UUID: V2ResourceTransferStaging] = [:]
    private var progressBindings: [UUID: V2ResourceNativeProgressBinding] = [:]
    private let operations = V2ResourceOperationScope(limit: 4)
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var permits: [UUID: V2RequestPermit] = [:]
    private var unmappedTaskIdentities: [Int: UUID] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var preparationDemands: [UUID: V2ByteTransferDemand] = [:]
    private var demandBindings: [UUID: UUID] = [:]
    private var pendingDemand: [UUID: V2NetworkWorkPriority] = [:]
    private var creating: Set<UUID> = []
    private var initialTargets: [UUID: V2ClientMediaTransferTarget] = [:]
    private var awaitingReceipt: [UUID: Date] = [:]
    private var waiters: [UUID: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var initialization: Task<Void, any Error>?
    private var reconciliation: Task<Void, any Error>?
    private var reconciliationDirty = false
    private var timer: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var initialized = false
    private var closed = false

    init(sessionID: UUID, accountID: UserID, store: GRDBV2LocalSyncStore,
                scheduler: V2AccountWorkScheduler, resolver: any V2ClientMediaDownloadTargetResolver,
                driver: any V2BackgroundDownloadSessionDriving, files: V2ResourceFileStore, root: URL,
                protectionWriter: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter(),
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.sessionID = sessionID; self.accountID = accountID; self.store = store
        self.scheduler = scheduler; self.resolver = resolver; self.driver = driver; self.now = now
        guard root.standardizedFileURL.path == files.backgroundDirectory.path else { throw V2AccountStorageError.scopeMismatch }
        self.files = files; byteInbox = .init(root: root, sessionID: sessionID, protection: protectionWriter)
        inbox = try .init(root: root.appendingPathComponent("downloads", isDirectory: true),
                          sessionID: sessionID, protectionWriter: protectionWriter)
    }

    #if os(iOS)
    public nonisolated static func native(accountID: UserID, store: GRDBV2LocalSyncStore,
        scheduler: V2AccountWorkScheduler, resources: V2ResourceCenter,
        resolver: any V2ClientMediaDownloadTargetResolver) async throws -> V2BackgroundDownloadCoordinator {
        try await resources.withBackgroundSetup(onCancelledValue: { await $0.close() }) { files, scope in
            guard accountID == scope.accountID, try await store.resourceFileJournal().accountID() == accountID else { throw V2AccountStorageError.scopeMismatch }
            let id = try await store.backgroundSessionID(), root = scope.backgroundDirectory
            try Task.checkCancellation()
            return try .init(sessionID: id, accountID: accountID, store: store, scheduler: scheduler,
                resolver: resolver, driver: V2NativeBackgroundSession.sharedDownload(sessionID: id, root: root), files: files, root: root)
        }
    }
    #endif

    func requireAttachment(accountID: UserID, files: V2ResourceFileStore) throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        guard self.accountID == accountID, self.files === files else { throw V2AccountStorageError.scopeMismatch }
    }

    public func initialize() async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        if initialized { return }
        if let initialization {
            do { try await initialization.value }
            catch V2BackgroundTransferError.protectedDataUnavailable { return }
            return
        }
        let work = Task { [self] in
            await self.driver.installWake { [weak self] in await self?.wake() }
            try await self.reconcile()
        }
        initialization = work
        do { try await work.value; initialized = true; initialization = nil }
        catch V2BackgroundTransferError.protectedDataUnavailable {
            // Wake delivery is installed and physical tasks are accounted for.
            // Protected business work resumes on the unlock notification.
            initialized = true; initialization = nil
        }
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

    func download(mediaID: MediaID, message: V2MediaMessageLocation?,
                         initialTarget: V2ClientMediaTransferTarget, restoringJobID: UUID? = nil) async throws -> V2BackgroundDownloadedFile {
        try await operations.run(onCancelledValue: { try? await self.didNotPublish($0) }) {
            try await self.performDownload(mediaID: mediaID, message: message, initialTarget: initialTarget, restoringJobID: restoringJobID)
        }
    }

    private func performDownload(mediaID: MediaID, message: V2MediaMessageLocation?,
                                 initialTarget: V2ClientMediaTransferTarget, restoringJobID: UUID?) async throws -> V2BackgroundDownloadedFile {
        _ = try V2BackgroundDownloadRequest.make(target: initialTarget)
        try await initialize()
        guard !closed else { throw V2BackgroundTransferError.closed }
        let job = try await store.beginBackgroundDownload(id: restoringJobID ?? UUID(), mediaID: mediaID, message: message,
            accountID: accountID, adoptMatching: restoringJobID == nil, retryPaused: true, requireExisting: restoringJobID != nil,
            priority: V2ByteTransferWorkScope.demand?.priority ?? V2NetworkWorkScope.context?.priority ?? .interactive)
        try await store.bindBackgroundDownloadBytes(id: job.id, target: initialTarget, accountID: accountID)
        let binding = UUID(), demand = V2ByteTransferWorkScope.demand
        demandBindings[binding] = job.id
        defer {
            demandBindings[binding] = nil; demand?.removeObserver(binding)
            releaseIdleDemand(job.id)
        }
        let priority = demand?.observe(binding) { [weak self] priority in
            Task { await self?.recordDemand(binding: binding, priority: priority) }
        } ?? V2NetworkWorkScope.context?.priority ?? .interactive
        try await promote(jobID: job.id, priority: priority)
        if case .preparing = job.state { initialTargets[job.id] = initialTarget }
        wake()
        try await reconcile()
        let task = try await waitForDownload(jobID: job.id)
        try Task.checkCancellation()
        guard !closed, try await currentJob(job.id)?.state == .downloaded(task) else { throw CancellationError() }
        let reservation = try await ensureReservation(task)
        try await files.rearmBackgroundDownload(task, reservation: reservation)
        try await files.verifyBackgroundDownload(task, reservation: reservation)
        try Task.checkCancellation()
        guard !closed, try await currentJob(job.id)?.state == .downloaded(task)
        else { throw CancellationError() }
        return .init(reservation: reservation, ownerID: ownerID, jobID: job.id, mappingID: task.id)
    }

    /// Called after FileStore published its verified copy. It alone revokes
    /// the callback permit, removes raw bytes and releases the one reservation.
    func didPublish(_ file: V2BackgroundDownloadedFile) async throws {
        guard file.ownerID == ownerID, !closed else { throw V2BackgroundTransferError.mappingConflict }
        // Commit the verified outcome before releasing its recoverable source.
        // A crash after this commit leaves only reclaimable staging, not an
        // apparently unfinished job whose sole completion marker was deleted.
        if try await store.retireBackgroundDownload(id: file.jobID, mappingID: file.mappingID, accountID: accountID, outcome: .completed) {
            try await discardSource(file.mappingID)
            try inbox.remove(file.mappingID)
        } else if try await store.backgroundDownloadIsCompleted(id: file.jobID, accountID: accountID) == false {
            throw CancellationError()
        }
        notify(file.jobID)
    }

    func didNotPublish(_ file: V2BackgroundDownloadedFile) async throws {
        guard file.ownerID == ownerID, !closed else { return }
        if let job = try await currentJob(file.jobID), case .downloaded(let task) = job.state,
           try await files.backgroundDownloadWasPublished(task) {
            try await didPublish(file)
        }
        // An unfinished copy keeps its raw-source claim. The next delivery
        // rearms publication capacity without making the source reclaimable.
    }

    /// A fresh authorized cache hit can satisfy an already received native
    /// download without leaving its raw inbox or capacity claim behind.
    func didUseVerifiedCache(jobID: UUID, fileID: V2LocalResourceFileID, checksum: V2ResourceChecksum, bytes: Int64) async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        guard let job = try await currentJob(jobID) else { return }
        guard case .downloaded(let task) = job.state else { return }
        guard task.checksum == checksum, task.expectedByteCount == bytes else { throw V2ResourceStorageError.integrityMismatch }
        let lease = try await files.borrowVerified(id: fileID, checksum: checksum, bytes: bytes)
        do {
            let actual = await driver.tasks()
            await driver.cancelAndDrain(actual.filter { $0.mappingID == task.id }.map(\.identifier))
            guard !closed, try await store.retireBackgroundDownload(id: jobID, mappingID: task.id, accountID: accountID, outcome: .completed) else { throw CancellationError() }
            try await discardSource(task.id); try inbox.remove(task.id)
            await release(task.id); notify(jobID)
            await lease.release()
        } catch { await lease.release(); throw error }
    }

    private func ensureReservation(_ task: V2BackgroundDownloadTask, suspended: Bool = false) async throws -> V2ResourceTransferStaging {
        if let existing = ownedReservations[task.id] { return existing }
        let reservation = try await files.adoptBackgroundDownload(task, suspended: suspended)
        ownedReservations[task.id] = reservation
        return reservation
    }
    private func discardSource(_ mapping: UUID) async throws {
        try await files.discardBackgroundDownload(mapping: mapping, session: sessionID)
        ownedReservations.removeValue(forKey: mapping)
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
            case .pausing, .paused: throw V2ResourceDownloadControlError.paused
            default: break
            }
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    private func currentJob(_ id: UUID) async throws -> V2BackgroundDownloadJob? {
        try await store.backgroundDownloads(accountID: accountID).first { $0.id == id }
    }
    private func wake() { wakes.continuation.yield(()) }
    private func recordDemand(binding: UUID, priority: V2NetworkWorkPriority) {
        guard !closed, let job = demandBindings[binding] else { return }
        if let pending = pendingDemand[job], pending.rawValue <= priority.rawValue { return }
        pendingDemand[job] = priority
        wake()
    }
    private func promote(jobID: UUID, priority: V2NetworkWorkPriority) async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        // Install the shared token before suspending for the transaction: a
        // concurrent preparer must join this token rather than a stale snapshot.
        let demand = preparationDemands[jobID] ?? V2ByteTransferDemand(priority: .background)
        preparationDemands[jobID] = demand
        defer { releaseIdleDemand(jobID) }
        guard let effective = try await store.promoteBackgroundDownload(id: jobID, accountID: accountID, priority: priority) else { return }
        guard !closed else { throw V2BackgroundTransferError.closed }
        demand.promote(to: effective)
        if let job = try await currentJob(jobID), case .transferring(let task) = job.state,
           let permit = permits[task.id], let promoted = await scheduler.promoteDownloadPermit(permit, to: effective) {
            permits[task.id] = promoted
        }
    }
    private func releaseIdleDemand(_ job: UUID) {
        if preparations[job] == nil, !demandBindings.values.contains(job) { preparationDemands[job] = nil }
    }
    private func notify(_ id: UUID) { if let values = waiters[id] { for waiter in values.values { waiter.yield(()) } } }
    private func release(_ id: UUID) async {
        progressBindings[id] = nil
        awaitingReceipt.removeValue(forKey: id)
        if let permit = permits.removeValue(forKey: id) { _ = await scheduler.release(permit) }
    }

    private func reconcile() async throws {
        if let reconciliation { reconciliationDirty = true; try await reconciliation.value; return }
        let work = Task {
            // Clear ownership before this task completes. A caller joining an
            // already completed task must never leave a dirty pulse unhandled.
            defer { self.reconciliation = nil }
            repeat {
                self.reconciliationDirty = false
                try await self.performReconciliation()
            } while self.reconciliationDirty && !self.closed
        }
        reconciliation = work
        try await work.value
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
                context: .init(service: "mediaProvider", priority: .background, kind: .byteTransfer(.download))) }
        }
        for (identifier, id) in unmappedTaskIdentities where !actual.contains(where: { $0.identifier == identifier }) {
            await release(id); unmappedTaskIdentities[identifier] = nil
        }
        // Minimal AFU permits remain readable while the business database is
        // locked. Expired physical work must drain before its slot is released.
        let admitted = Dictionary(try byteInbox.permits().map { ($0.mappingID, $0) }, uniquingKeysWith: { first, _ in first })
        for task in actual {
            if let id = task.mappingID, creating.contains(id) { continue }
            let permit = task.mappingID.flatMap { admitted[$0] }
            let expired = permit.map { Double($0.expiresAtMilliseconds) <= now().timeIntervalSince1970 * 1000 } ?? true
            if permit?.state.identifier != task.identifier || expired {
                // A prepared mapping may belong to the crash window between
                // durable task installation and permit installation. Only an
                // already suspended task can wait for the protected journal.
                if permit?.state == .prepared && task.suspended && !expired { continue }
                await driver.cancelAndDrain([task.identifier])
                if let id = identities[task.identifier] { await release(id) }
            }
        }
        if let protection = driver as? any V2BackgroundProtectedDataChecking,
           !(await protection.protectedDataAvailable()) {
            if let deadline = admitted.values.map({ Date(timeIntervalSince1970: Double($0.expiresAtMilliseconds) / 1000) })
                .filter({ $0 > now() }).min() { scheduleWake(at: deadline) }
            throw V2BackgroundTransferError.protectedDataUnavailable
        }
        let jobs = try await store.backgroundDownloads(accountID: accountID)
        for (job, priority) in pendingDemand {
            pendingDemand[job] = nil
            do { try await promote(jobID: job, priority: priority) }
            catch {
                if pendingDemand[job].map({ priority.rawValue < $0.rawValue }) ?? true { pendingDemand[job] = priority }
                throw error
            }
        }
        // Initial adoption is conservative while protected data is unavailable.
        // Once readable, restore the persisted user's classification in place.
        for job in jobs {
            if case .transferring(let task) = job.state, let permit = permits[task.id],
               let updated = await scheduler.promoteDownloadPermit(permit, to: job.priority) { permits[task.id] = updated }
        }
        let mappings = Dictionary(jobs.compactMap { job -> (UUID, V2BackgroundDownloadTask)? in
            switch job.state {
            case .transferring(let task), .downloaded(let task): (task.id, task)
            case .cancelled(let task), .pausing(let task): task.map { ($0.id, $0) }
            default: nil
            }
        }, uniquingKeysWith: { first, _ in first })
        let candidates = actual.filter { task in
            guard let id = task.mappingID else { return true }
            if creating.contains(id) { return false }
            return mappings[id]?.identifier != task.identifier || mappings[id]?.sessionID != sessionID
        }
        var orphans: [V2BackgroundSystemTask] = []
        for task in candidates {
            if let id = task.mappingID {
                if creating.contains(id) { continue }
                let current = try await store.backgroundDownloads(accountID: accountID)
                if creating.contains(id) { continue }
                let matched = current.contains { job in
                    let mapping: V2BackgroundDownloadTask?
                    switch job.state {
                    case .transferring(let value), .downloaded(let value): mapping = value
                    case .cancelled(let value), .pausing(let value): mapping = value
                    default: mapping = nil
                    }
                    return mapping?.id == id && mapping?.identifier == task.identifier && mapping?.sessionID == sessionID
                }
                if matched { continue }
            }
            orphans.append(task)
        }
        if !orphans.isEmpty {
            await driver.cancelAndDrain(orphans.map(\.identifier))
            for task in orphans { if let id = identities[task.identifier] { await release(id) } }
        }
        let receipts = try inbox.results()
        let byID = Dictionary(receipts.map { ($0.mappingID, $0) }, uniquingKeysWith: { _, last in last })
        var nextWake = now().addingTimeInterval(900)
        var needsTimer = false
        for job in jobs {
            try Task.checkCancellation()
            guard !closed else { throw V2BackgroundTransferError.closed }
            switch job.state {
            case .transferring(let task):
                // Creation installs the journal before resume, and either step
                // can interleave with this reconciliation's earlier snapshot.
                // The preparer owns that transition until resume has returned.
                if creating.contains(task.id) { continue }
                let latestTasks = await driver.tasks()
                guard try await currentJob(job.id)?.state == .transferring(task) else { wake(); continue }
                let active = latestTasks.first { $0.mappingID == task.id && $0.identifier == task.identifier }
                if let active {
                    awaitingReceipt.removeValue(forKey: task.id)
                    do { _ = try await ensureReservation(task, suspended: active.suspended) }
                    catch {
                        await driver.cancelAndDrain([active.identifier])
                        _ = try await store.finishBackgroundDownloadTask(id: job.id, mappingID: task.id, sessionID: sessionID,
                            identifier: task.identifier, success: false, accountID: accountID)
                        try await discardSource(task.id)
                        await release(task.id); notify(job.id); wake(); continue
                    }
                    progressBindings[task.id] = .init(transfer: .download(job.id), mapping: task.id, identifier: task.identifier,
                        expectedBytes: task.expectedByteCount, expiresAt: task.expiresAt)
                    if task.expiresAt <= now() {
                        await driver.cancelAndDrain([active.identifier]); wake()
                    } else if byID[task.id] != nil {
                        nextWake = min(nextWake, now().addingTimeInterval(0.2)); needsTimer = true
                    } else {
                        if active.suspended { try await driver.resume(active.identifier) }
                        nextWake = min(nextWake, task.expiresAt); needsTimer = true
                    }
                } else {
                    // The initial receipt snapshot predates the awaited task
                    // query. A completion can arrive between them: re-read
                    // after observing absence, or a successful download would
                    // be retried and its real receipt discarded as an orphan.
                    let result = try inbox.results().first { $0.mappingID == task.id }
                    if result == nil {
                        let firstMissing = awaitingReceipt[task.id] ?? now()
                        awaitingReceipt[task.id] = firstMissing
                        let deadline = min(task.expiresAt, firstMissing.addingTimeInterval(2))
                        if deadline > now() {
                            nextWake = min(nextWake, min(deadline, now().addingTimeInterval(0.2)))
                            needsTimer = true
                            continue
                        }
                    }
                    awaitingReceipt.removeValue(forKey: task.id)
                    var success = result.map { $0.taskIdentifier == task.identifier && $0.errorCode == nil && $0.statusCode == 200
                        && $0.receivedBytes == task.expectedByteCount && $0.originDigest == task.originDigest } ?? false
                    if success {
                        do {
                            let reservation = try await ensureReservation(task)
                            try await files.verifyBackgroundDownload(task, reservation: reservation)
                        }
                        catch { success = false }
                    }
                    _ = try await store.finishBackgroundDownloadTask(id: job.id, mappingID: task.id, sessionID: task.sessionID,
                        identifier: task.identifier, success: success, accountID: accountID)
                    try inbox.remove(task.id)
                    if !success { try await discardSource(task.id); wake() }
                    await release(task.id); notify(job.id)
                }
            case .preparing:
                guard try await currentJob(job.id)?.state == .preparing else { wake(); continue }
                let retry = Date(timeIntervalSince1970: Double(job.retryAtMilliseconds) / 1_000)
                if retry > now() { nextWake = min(nextWake, retry); needsTimer = true }
                else if preparations[job.id] == nil {
                    let demand = preparationDemands[job.id] ?? V2ByteTransferDemand(priority: job.priority)
                    demand.promote(to: job.priority)
                    preparationDemands[job.id] = demand
                    preparations[job.id] = Task {
                        await V2ByteTransferWorkScope.$demand.withValue(demand) { await self.prepare(job) }
                    }
                }
            case .pausing:
                if let preparation = preparations[job.id] {
                    preparation.cancel(); await preparation.value
                }
                guard let latest = try await currentJob(job.id), case .pausing(let task) = latest.state else { wake(); continue }
                if let task {
                    let actual = await driver.tasks()
                    await driver.cancelAndDrain(actual.filter { $0.mappingID == task.id }.map(\.identifier))
                    try inbox.remove(task.id)
                    try await discardSource(task.id)
                    await release(task.id)
                }
                try await store.finishBackgroundDownloadPause(id: job.id, mappingID: task?.id, accountID: accountID)
                notify(job.id); wake()
            case .cancelled:
                // Creation can have produced a suspended OS task without
                // installing its mapping yet. Its owner must actually drain,
                // not merely receive cancellation, before the job can finish.
                if let preparation = preparations[job.id] {
                    preparation.cancel()
                    await preparation.value
                }
                guard let latest = try await currentJob(job.id), case .cancelled(let task) = latest.state else { wake(); continue }
                if let task {
                    // A task may have been created since the initial snapshot;
                    // never retire its mapping/permit using that stale absence.
                    let latestTasks = await driver.tasks()
                    await driver.cancelAndDrain(latestTasks.filter { $0.mappingID == task.id }.map(\.identifier))
                    await release(task.id); try inbox.remove(task.id)
                    try await discardSource(task.id)
                }
                _ = try await store.retireBackgroundDownload(id: job.id, mappingID: task?.id, accountID: accountID, outcome: .cancelled)
                notify(job.id)
            case .downloaded(let task):
                // A cold owner may find the publication committed before the
                // raw-source retirement. Do not reserve a second publication.
                if ownedReservations[task.id] == nil, try await files.backgroundDownloadWasPublished(task) {
                    _ = try await store.retireBackgroundDownload(id: job.id, mappingID: task.id, accountID: accountID, outcome: .completed)
                    try inbox.remove(task.id)
                } else {
                    do {
                        let reservation = try await ensureReservation(task)
                        try await files.verifyBackgroundDownload(task, reservation: reservation)
                    } catch {
                        try await discardSource(task.id)
                        _ = try await store.retireBackgroundDownload(id: job.id, mappingID: task.id, accountID: accountID, outcome: .failed(.unavailable))
                        try inbox.remove(task.id)
                    }
                }
                notify(job.id)
            case .paused: notify(job.id)
            }
        }
        for receipt in receipts where mappings[receipt.mappingID] == nil && !creating.contains(receipt.mappingID) {
            try inbox.remove(receipt.mappingID)
        }
        let current = try await store.backgroundDownloads(accountID: accountID)
        let retained = Set(current.compactMap { job -> UUID? in
            switch job.state {
            case .transferring(let task), .downloaded(let task): task.id
            case .cancelled(let task), .pausing(let task): task?.id
            default: nil
            }
        }).union(creating)
        try await files.reconcileBackgroundDownloads(session: sessionID, retained: retained)
        timer?.cancel(); timer = nil
        if needsTimer {
            scheduleWake(at: nextWake)
        }
    }

    private func scheduleWake(at deadline: Date) {
        timer?.cancel()
        let delay = max(0.05, deadline.timeIntervalSince(now()))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)); await self?.wake() } catch { }
        }
    }

    private func prepare(_ job: V2BackgroundDownloadJob) async {
        let mappingID = UUID()
        defer { creating.remove(mappingID); preparations[job.id] = nil; releaseIdleDemand(job.id); initialTargets[job.id] = nil; wake() }
        var taskIdentifier: Int?, installed = false
        do {
            var target: V2ClientMediaTransferTarget
            if let initial = initialTargets.removeValue(forKey: job.id), initial.expiresAt > now() { target = initial }
            else { target = try await resolver.resolveDownloadTarget(mediaID: job.mediaID, message: job.message) }
            let journal = await store.resourceFileJournal()
            let automatic = preparationDemands[job.id]?.priority == .background
            if automatic { try journal.requireAutomaticDownloadAllowed(mediaID: job.mediaID, message: job.message, target: target) }
            let preferences = try journal.downloadNetworkPreferences()
            target = target.restrictingNetwork(to: preferences.constraints(automatic: automatic))
            _ = try V2BackgroundDownloadRequest.make(target: target)
            try await store.bindBackgroundDownloadBytes(id: job.id, target: target, accountID: accountID)
            guard let grant = target.backgroundDownloadAuthorization, let origin = V2BackgroundResultInbox.originDigest(target.url)
            else { throw V2BackgroundTransferError.invalidAuthorization }
            let permit = try await scheduler.acquire(.init(service: "mediaProvider", priority: job.priority, kind: .byteTransfer(.download),
                isRetry: job.attemptCount > 0), deadline: .now.advanced(by: .seconds(min(15, target.expiresAt.timeIntervalSince(now())))))
            permits[mappingID] = permit; creating.insert(mappingID)
            try Task.checkCancellation()
            guard !closed, try await currentJob(job.id)?.state == .preparing else { throw CancellationError() }
            let reservation = try await files.reserveBackgroundDownload(mapping: mappingID, session: sessionID, target: target)
            ownedReservations[mappingID] = reservation
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            let identifier = try await driver.create(target: target, mappingID: mappingID); taskIdentifier = identifier
            let task = try V2BackgroundDownloadTask(id: mappingID, sessionID: sessionID, identifier: identifier,
                grantID: grant.id, expectedByteCount: target.expectedByteCount, checksum: target.checksum,
                originDigest: origin, expiresAtMilliseconds: grant.expiresAtMilliseconds)
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            try await store.installBackgroundDownloadTask(id: job.id, task: task, accountID: accountID); installed = true
            try await files.installBackgroundDownload(reservation, task: task)
            progressBindings[mappingID] = .init(transfer: .download(job.id), mapping: mappingID, identifier: identifier,
                expectedBytes: task.expectedByteCount, expiresAt: task.expiresAt)
            try Task.checkCancellation(); guard !closed, task.expiresAt > now() else { throw CancellationError() }
            try await driver.resume(identifier)
        } catch {
            if let taskIdentifier { await driver.cancelAndDrain([taskIdentifier]) }
            if installed, let taskIdentifier {
                _ = try? await store.finishBackgroundDownloadTask(id: job.id, mappingID: mappingID, sessionID: sessionID,
                    identifier: taskIdentifier, success: false, accountID: accountID)
            } else if error as? V2ResourceAutomaticDownloadError == .policyRestricted {
                try? await store.restrictAutomaticBackgroundDownload(id: job.id, accountID: accountID)
            } else { try? await store.failBackgroundDownloadPreparation(id: job.id, accountID: accountID) }
            try? await discardSource(mappingID)
            creating.remove(mappingID); await release(mappingID); notify(job.id)
        }
    }

    func transferProgress() async -> [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] {
        guard !closed, !progressBindings.isEmpty else { return [:] }
        let actual = await driver.tasks()
        guard !closed else { return [:] }
        let bindings = progressBindings.filter { permits[$0.key] != nil && ownedReservations[$0.key] != nil && !creating.contains($0.key) }.map(\.value)
        return V2ResourceNativeProgress.snapshot(bindings: bindings, tasks: actual, now: now())
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

    /// A page only records the command. The account reconciliation owns actual
    /// OS drain, source cleanup and terminal publication after this returns.
    func requestCancellation(jobID: UUID) async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        try await store.requestBackgroundDownloadCancellation(id: jobID, accountID: accountID)
        preparations[jobID]?.cancel()
        notify(jobID); wake()
    }

    func requestPause(jobID: UUID) async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        try await store.requestBackgroundDownloadPause(id: jobID, accountID: accountID)
        preparations[jobID]?.cancel()
        notify(jobID); wake()
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
                case .cancelled(let value), .pausing(let value): task = value
                default: task = nil
                }
                if let task { try? inbox.remove(task.id) }
                _ = try? await store.retireBackgroundDownload(id: job.id, mappingID: task?.id, accountID: accountID, outcome: .cancelled)
            }
        }
        for id in Array(ownedReservations.keys) { try? await discardSource(id) }
        try? await files.reconcileBackgroundDownloads(session: sessionID, retained: [])
        for id in Array(permits.keys) { await release(id) }
        awaitingReceipt.removeAll()
        wakes.continuation.finish()
        #if os(iOS)
        (driver as? V2NativeBackgroundSession)?.invalidateAfterDrain()
        #endif
    }

}
