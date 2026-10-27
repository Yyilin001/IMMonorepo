import Foundation
import IMV2Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One account owns system tasks and durable mappings. Initialization adopts every actual
/// task before foreground admission; a system completion only schedules same-job status.
public actor V2BackgroundTransferCoordinator {
    public nonisolated let sessionID:UUID
    private let activationID:UUID
    private let store:GRDBV2LocalSyncStore
    private let scheduler:V2AccountWorkScheduler
    private let diagnostics:V2NetworkDiagnostics?
    private let driver:any V2BackgroundSessionDriving
    private let inbox:V2BackgroundResultInbox
    private let files: V2ResourceFileStore
    private var ownedSources: Set<UUID> = []
    private var unmappedTaskIdentities: [Int: UUID] = [:]
    private var progressBindings: [UUID: V2BackgroundTaskMapping] = [:]
    private let operations=V2ResourceOperationScope(limit:16)
    private let wakes=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
    private var permits:[UUID:V2RequestPermit]=[:]
    private var cancellationStarted:[UUID:ContinuousClock.Instant]=[:]
    private var creating:Set<UUID>=[]
    private var closed=false
    private var initialized=false
    private var initialization:Task<Void,any Error>?
    private var reconciliation:Task<Void,any Error>?
    private var reconciliationDirty=false
    private var closing:Task<Void,Never>?
    private var expiryWake:Task<Void,Never>?
    init(sessionID:UUID,activationID:UUID,store:GRDBV2LocalSyncStore,scheduler:V2AccountWorkScheduler,
                driver:any V2BackgroundSessionDriving,files:V2ResourceFileStore,root:URL,protectionWriter:any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter(),diagnostics:V2NetworkDiagnostics? = nil) throws {
        self.diagnostics=diagnostics;self.sessionID=sessionID;self.activationID=activationID;self.store=store;self.scheduler=scheduler
        guard root.isFileURL, root.standardizedFileURL.path == files.backgroundDirectory.path else { throw V2AccountStorageError.scopeMismatch }
        self.driver=driver;self.files=files
        self.inbox=try .init(root:root,sessionID:sessionID,protectionWriter:protectionWriter)
    }
    public nonisolated static func defaultRoot() throws -> URL {
        try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:false)
            .appendingPathComponent("IMV2BackgroundTransfers",isDirectory:true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    #if os(iOS)
    public nonisolated static func native(store:GRDBV2LocalSyncStore,scheduler:V2AccountWorkScheduler,
                                         resources:V2ResourceCenter,activationID:UUID,diagnostics:V2NetworkDiagnostics? = nil) async throws -> V2BackgroundTransferCoordinator {
        try await resources.withBackgroundSetup(onCancelledValue: { await $0.close() }) { files, scope in
            guard try await store.resourceFileJournal().accountID() == scope.accountID else { throw V2AccountStorageError.scopeMismatch }
            let id=try await store.backgroundSessionID(),root=scope.backgroundDirectory
            try Task.checkCancellation()
            let driver=try V2NativeBackgroundSession.shared(sessionID:id,root:root)
            return try .init(sessionID:id,activationID:activationID,store:store,scheduler:scheduler,driver:driver,files:files,root:root,diagnostics:diagnostics)
        }
    }
    #endif
    public func initialize() async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        if initialized { return }
        if let initialization { try await initialization.value;return }
        let work=Task { [self] in
            await self.driver.installWake { [weak self] in if let self { await self.wake() } }
            try await self.reconcile()
            self.wake()
        }
        initialization=work
        do {
            try await work.value
            initialized=true;initialization=nil
        } catch { initialization=nil;throw error }
    }
    private func wake() { wakes.continuation.yield(()) }
    private func beginCancellation(_ ids: [UUID]) {
        let instant = ContinuousClock.now
        for id in ids where permits[id] != nil && cancellationStarted[id] == nil { cancellationStarted[id] = instant }
    }
    private func releasePermit(_ id: UUID) async {
        progressBindings[id] = nil
        guard let permit = permits.removeValue(forKey: id) else { cancellationStarted[id] = nil; return }
        let started = cancellationStarted.removeValue(forKey: id)
        let released = await scheduler.release(permit)
        if released, let started {
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            diagnostics?.record(V2BackgroundTransferMetric(result: nil, cancellationToPermitRelease: seconds))
        }
    }

    /// Account runtime owns this activity independently of TCP and pages.
    public func run() async throws {
        do {
            do { try await initialize() }
            catch V2BackgroundTransferError.protectedDataUnavailable {
                // Wake delivery and physical accounting are already installed.
                // Unlock retries protected reconciliation without retiring work.
            }
            for await _ in wakes.stream {
                try Task.checkCancellation()
                do { try await reconcile() }
                catch {
                    if let protection=driver as? any V2BackgroundProtectedDataChecking,
                       !(await protection.protectedDataAvailable()) { continue }
                    throw error
                }
            }
            try Task.checkCancellation()
        } catch {
            // A failed owner cannot leave adopted physical tasks holding scheduler
            // slots after its activity has ended. Durable mappings remain recoverable.
            await close()
            throw error
        }
    }
    public func enqueue(job:V2ResourceTransferJob,resourceOwner:UUID,plan:V2ResourceTransferPlan,source:V2ResourceFileLease) async throws {
        try await operations.run { try await self.performEnqueue(job:job,resourceOwner:resourceOwner,plan:plan,source:source) }
    }
    private func performEnqueue(job:V2ResourceTransferJob,resourceOwner:UUID,plan:V2ResourceTransferPlan,source:V2ResourceFileLease) async throws {
        try await initialize()
        guard !closed,case .messageAttachment = job.request.usage,job.request.clientModes.contains(plan.mode),
              let session=job.session,let grant=plan.backgroundAuthorization,
              grant.sessionID==session.locator.sessionID,grant.generation==session.generation,grant.mediaID==job.request.mediaID,
              grant.expiresAt>Date(),let origin=V2BackgroundResultInbox.originDigest(plan.url)
        else { throw V2BackgroundTransferError.invalidAuthorization }
        switch grant.scope {
        case .part(let number):
            guard plan.mode == .httpPartPut, let range = plan.byteRange, plan.partNumber == number,
                  plan.expectedByteCount == range.byteCount, range.upperBound < job.request.byteCount else { throw V2BackgroundTransferError.invalidAuthorization }
        case .whole(let bytes, let checksum):
            guard plan.mode == .httpPut, plan.partNumber == nil, plan.byteRange == nil,
                  bytes == job.request.byteCount, plan.expectedByteCount == bytes,
                  checksum == job.request.checksum, plan.checksum == checksum else { throw V2BackgroundTransferError.invalidAuthorization }
        }
        let id=UUID()
        let context=V2NetworkWorkContext(service:"mediaProvider",priority:V2NetworkWorkScope.context?.priority ?? .recovery,kind:.byteTransfer(.upload),
            isRetry:V2NetworkWorkScope.context?.isRetry ?? false)
        let deadline=ContinuousClock.now.advanced(by:.seconds(min(15,max(0,grant.expiresAt.timeIntervalSinceNow))))
        let permit=try await scheduler.acquire(context,deadline:min(deadline,V2HTTPRequestDeadline.current ?? deadline))
        creating.insert(id);permits[id]=permit
        var taskID:Int?
        var installed=false
        do {
            try Task.checkCancellation();guard !closed else { throw V2BackgroundTransferError.closed }
            ownedSources.insert(id)
            let destination: URL
            switch grant.scope {
            case .part:
                guard let range = plan.byteRange else { throw V2BackgroundTransferError.invalidAuthorization }
                destination = try await files.makeBackgroundUploadSource(from: source, sessionID: sessionID, id: id, range: range)
            case .whole:
                destination = try await files.makeBackgroundWholeUploadSource(from: source, sessionID: sessionID, id: id)
            }
            if let checksum=plan.checksum {
                guard try V2ResourceFileDigest.sha256(fileURL:destination,expectedByteCount:plan.expectedByteCount)==checksum.value else {
                    throw V2ClientMediaTransferError.checksumMismatch
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw V2BackgroundTransferError.closed }
            guard grant.expiresAt>Date() else { throw V2BackgroundTransferError.invalidAuthorization }
            var request=URLRequest(url:plan.url,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:30)
            request.httpMethod="PUT"
            for header in plan.headers { request.setValue(header.value,forHTTPHeaderField:header.name) }
            let identifier=try await driver.create(request:request,file:destination,mappingID:id);taskID=identifier
            try Task.checkCancellation();guard !closed else { throw V2BackgroundTransferError.closed }
            let mapping=V2BackgroundTaskMapping(id:id,sessionID:sessionID,jobID:job.id,activationID:activationID,sourceToken:id,
                taskIdentifier:identifier,partNumber:grant.partNumber,expectedBytes:plan.expectedByteCount,expiresAt:grant.expiresAt,originDigest:origin)
            // The newly created OS task is suspended until both sides are durably associated.
            try await store.installBackgroundMapping(mapping,resourceOwner:resourceOwner)
            installed=true;creating.remove(id);permits[id]=permit
            progressBindings[id] = mapping
            try Task.checkCancellation();guard !closed else { throw V2BackgroundTransferError.closed }
            guard grant.expiresAt>Date() else { throw V2BackgroundTransferError.invalidAuthorization }
            try await driver.resume(identifier)
            // Initialization reconciled before this mapping existed. Schedule the
            // new grant's expiry even if the system task never sends a callback.
            wake()
        } catch {
            creating.remove(id)
            if let taskID { beginCancellation([id]); await driver.cancelAndDrain([taskID]) }
            if installed {
                if let mappings=try? await store.activeBackgroundMappings(session:sessionID),
                   let mapping=mappings.first(where:{$0.id==id}) {
                    // Cleanup must not depend on protected business DB availability. The
                    // durable mapping survives and the next owner reconciles same-job status.
                    if (try? await store.completeBackgroundMapping(mapping,result:nil)) == true {
                        diagnostics?.record(V2BackgroundTransferMetric(result:nil))
                    }
                }
            }
            try? await files.releaseBackgroundUploadSource(id:id,sessionID:sessionID)
            ownedSources.remove(id)
            wake()
            await releasePermit(id)
            throw error
        }
    }
    private func reconcile() async throws {
        if let reconciliation {
            reconciliationDirty=true
            try await reconciliation.value
            return
        }
        let work=Task { [self] in
            // Ownership ends in the task's actor turn, before value completes;
            // late joiners cannot strand a newly marked reconciliation pulse.
            defer { self.reconciliation=nil }
            repeat {
                self.reconciliationDirty=false
                try await self.performReconciliation()
            } while self.reconciliationDirty && !self.closed
        }
        reconciliation=work
        try await work.value
    }
    private func performReconciliation() async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        let actual=await driver.tasks()
        guard actual.count<=64 else { await driver.cancelAndDrain(actual.map(\.identifier));throw V2BackgroundTransferError.capacityExceeded }
        // Physical OS work occupies byte slots even while its business journal
        // is locked. Stable orphan identities prevent repeated lock wakes from
        // adopting the same task more than once.
        for task in actual {
            let id = task.mappingID ?? unmappedTaskIdentities[task.identifier] ?? UUID()
            if task.mappingID == nil { unmappedTaskIdentities[task.identifier] = id }
            if permits[id] == nil {
                permits[id] = try await scheduler.adoptExistingByteTransfer(id: id,
                    context: .init(service: "mediaProvider", priority: .background, kind: .byteTransfer(.upload)))
            }
        }
        for (identifier, id) in unmappedTaskIdentities where !actual.contains(where: { $0.identifier == identifier }) {
            await releasePermit(id); unmappedTaskIdentities[identifier] = nil
        }
        if let protection=driver as? any V2BackgroundProtectedDataChecking,
           !(await protection.protectedDataAvailable()) { throw V2BackgroundTransferError.protectedDataUnavailable }
        let mappings=try await store.activeBackgroundMappings(session:sessionID)
        let byID=Dictionary(uniqueKeysWithValues:mappings.map { ($0.id,$0) })
        var orphans:[(Int,UUID)]=[]
        // Adopt all actual slots before cancelling or resuming any task or doing DB result work.
        for task in actual {
            guard let id = task.mappingID ?? unmappedTaskIdentities[task.identifier] else {
                throw V2BackgroundTransferError.mappingConflict
            }
            if creating.contains(id) { continue }
            if let mapping=byID[id],mapping.taskIdentifier==task.identifier { }
            else { orphans.append((task.identifier,id)) }
        }
        if !orphans.isEmpty {
            beginCancellation(orphans.map(\.1))
            await driver.cancelAndDrain(orphans.map(\.0))
            for (_,id) in orphans { await releasePermit(id) }
        }
        let receipts=try inbox.results()
        let resultByID=Dictionary(receipts.map { ($0.mappingID,$0) },uniquingKeysWith:{ _,latest in latest })
        var completedSources: Set<UUID> = []
        for mapping in mappings {
            let task=actual.first { $0.mappingID==mapping.id && $0.identifier==mapping.taskIdentifier }
            if let task {
                do {
                    try await files.adoptBackgroundUploadSource(id:mapping.sourceToken,sessionID:sessionID)
                    ownedSources.insert(mapping.sourceToken)
                } catch {
                    beginCancellation([mapping.id])
                    await driver.cancelAndDrain([task.identifier])
                    _ = try await store.completeBackgroundMapping(mapping,result:nil)
                    try? await files.releaseBackgroundUploadSource(id:mapping.sourceToken,sessionID:sessionID)
                    ownedSources.remove(mapping.sourceToken);completedSources.insert(mapping.sourceToken)
                    await releasePermit(mapping.id)
                    continue
                }
            }
            if try await store.resourceTransfer(id: mapping.jobID)?.control == .pause {
                if let task {
                    beginCancellation([mapping.id])
                    await driver.cancelAndDrain([task.identifier])
                }
                _ = try await store.completeBackgroundMapping(mapping, result: nil)
                try inbox.remove(mapping.id)
                try await files.releaseBackgroundUploadSource(id: mapping.sourceToken, sessionID: sessionID)
                ownedSources.remove(mapping.sourceToken); completedSources.insert(mapping.sourceToken)
                await releasePermit(mapping.id)
                continue
            }
            if let receipt=resultByID[mapping.id],receipt.taskIdentifier==mapping.taskIdentifier {
                // If a forged/duplicate result races a still-active task, do not release its slot.
                if task != nil { continue }
                if [429,503].contains(receipt.statusCode ?? 0),let retry=receipt.retryNotBefore {
                    await scheduler.coolDown(service:"mediaProvider",for:retry.timeIntervalSinceNow)
                }
                if try await store.completeBackgroundMapping(mapping,result:receipt) {
                    diagnostics?.record(V2BackgroundTransferMetric(result:receipt))
                }
                try inbox.remove(mapping.id)
                await releasePermit(mapping.id)
                try await files.releaseBackgroundUploadSource(id:mapping.sourceToken,sessionID:sessionID)
                ownedSources.remove(mapping.sourceToken);completedSources.insert(mapping.sourceToken)
            } else if task==nil {
                // Created/completed-but-unmapped or first-unlock inbox failures never mint a new job.
                if try await store.completeBackgroundMapping(mapping,result:nil) {
                    diagnostics?.record(V2BackgroundTransferMetric(result:nil))
                }
                await releasePermit(mapping.id)
                try await files.releaseBackgroundUploadSource(id:mapping.sourceToken,sessionID:sessionID)
                ownedSources.remove(mapping.sourceToken);completedSources.insert(mapping.sourceToken)
            } else if let task {
                progressBindings[mapping.id] = mapping
                if mapping.expiresAt<=Date() {
                    beginCancellation([mapping.id])
                    await driver.cancelAndDrain([task.identifier]);wakes.continuation.yield(())
                } else if task.suspended { try await driver.resume(task.identifier) }
            }
        }
        for result in receipts where byID[result.mappingID]==nil { try inbox.remove(result.mappingID) }
        let retained=Set(mappings.map(\.sourceToken)).subtracting(completedSources).union(creating)
        if try await files.reconcileBackgroundUploadSources(sessionID:sessionID,retained:retained) {
            // Continue bounded reclamation on the account loop; orphan buildup
            // must not permanently prevent initialization after repeated crashes.
            wakes.continuation.yield(())
        }
        expiryWake?.cancel()
        if let expiry=mappings.map(\.expiresAt).filter({ $0>Date() }).min() {
            expiryWake=Task { [weak self] in
                do { try await Task.sleep(for:.seconds(max(0,expiry.timeIntervalSinceNow))); await self?.wake() }
                catch { }
            }
        }

    }

    func transferProgress() async -> [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] {
        guard !closed, !progressBindings.isEmpty else { return [:] }
        let actual = await driver.tasks()
        guard !closed else { return [:] }
        let bindings = progressBindings.values.compactMap { mapping -> V2ResourceNativeProgressBinding? in
            guard permits[mapping.id] != nil, ownedSources.contains(mapping.sourceToken), !creating.contains(mapping.id) else { return nil }
            return .init(transfer: .upload(mapping.jobID), mapping: mapping.id, identifier: mapping.taskIdentifier,
                expectedBytes: mapping.expectedBytes, expiresAt: mapping.expiresAt)
        }
        return V2ResourceNativeProgress.snapshot(bindings: bindings, tasks: actual, now: Date())
    }
    public func cancel(jobID:UUID) async throws {
        try await initialize()
        let mappings=try await store.activeBackgroundMappings(session:sessionID).filter { $0.jobID==jobID }
        beginCancellation(mappings.map(\.id))
        await driver.cancelAndDrain(mappings.map(\.taskIdentifier))
        try await reconcile()
    }
    public func close() async {
        if let closing { await closing.value; return }
        let task=Task { await self.performClose() }; closing=task
        await task.value
    }
    private func performClose() async {
        guard !closed else { return }
        beginCancellation(Array(permits.keys))
        closed=true;initialization?.cancel();_ = await initialization?.result
        expiryWake?.cancel()
        await operations.close()
        _ = await reconciliation?.result
        let actual=await driver.tasks()
        await driver.cancelAndDrain(actual.map(\.identifier))
        if let mappings=try? await store.activeBackgroundMappings(session:sessionID) {
            for mapping in mappings {
                if (try? await store.completeBackgroundMapping(mapping,result:nil)) == true {
                    diagnostics?.record(V2BackgroundTransferMetric(result:nil))
                }
            }
        }
        for id in ownedSources { try? await files.releaseBackgroundUploadSource(id:id,sessionID:sessionID) }
        ownedSources.removeAll()
        _ = try? await files.reconcileBackgroundUploadSources(sessionID:sessionID,retained:[])
        for id in Array(permits.keys) { await releasePermit(id) }
        permits.removeAll();unmappedTaskIdentities.removeAll();cancellationStarted.removeAll();wakes.continuation.finish()
        #if os(iOS)
        (driver as? V2NativeBackgroundSession)?.invalidateAfterDrain()
        #endif
    }
}
