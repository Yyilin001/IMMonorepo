import Foundation
import IMV2Core
import Synchronization
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
    private let root:URL
    private let protectionWriter:any V2ResourceFileProtectionWriting
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
    private nonisolated static let sourcePreparation=Mutex(())
    public init(sessionID:UUID,activationID:UUID,store:GRDBV2LocalSyncStore,scheduler:V2AccountWorkScheduler,
                driver:any V2BackgroundSessionDriving,root:URL,protectionWriter:any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter(),diagnostics:V2NetworkDiagnostics? = nil) throws {
        self.diagnostics=diagnostics;self.sessionID=sessionID;self.activationID=activationID;self.store=store;self.scheduler=scheduler
        self.driver=driver;self.root=root;self.protectionWriter=protectionWriter
        self.inbox=try .init(root:root,sessionID:sessionID,protectionWriter:protectionWriter)
        try V2ResourceStagingBudget.register(directory:root,background:true)
    }
    public nonisolated static func defaultRoot() throws -> URL {
        try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:false)
            .appendingPathComponent("IMV2BackgroundTransfers",isDirectory:true)
    }
    #if os(iOS)
    public nonisolated static func native(store:GRDBV2LocalSyncStore,scheduler:V2AccountWorkScheduler,
                                         activationID:UUID,diagnostics:V2NetworkDiagnostics? = nil) async throws -> V2BackgroundTransferCoordinator {
        let id=try await store.backgroundSessionID(),root=try defaultRoot()
        let driver=try V2NativeBackgroundSession.shared(sessionID:id,root:root)
        return try .init(sessionID:id,activationID:activationID,store:store,scheduler:scheduler,driver:driver,root:root,diagnostics:diagnostics)
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
            try await initialize()
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
    public func enqueue(job:V2ResourceTransferJob,resourceOwner:UUID,plan:V2ResourceTransferPlan,source:URL) async throws {
        try await operations.run { try await self.performEnqueue(job:job,resourceOwner:resourceOwner,plan:plan,source:source) }
    }
    private func performEnqueue(job:V2ResourceTransferJob,resourceOwner:UUID,plan:V2ResourceTransferPlan,source:URL) async throws {
        try await initialize()
        guard !closed,case .messageAttachment = job.request.usage,
              let session=job.session,let grant=plan.backgroundAuthorization,
              grant.sessionID==session.locator.sessionID,grant.generation==session.generation,grant.mediaID==job.request.mediaID,
              plan.mode == .httpPartPut,let range=plan.byteRange,let part=plan.partNumber,
              grant.partNumber==part,grant.expiresAt>Date(),plan.expectedByteCount==range.byteCount,
              range.upperBound<job.request.byteCount,let origin=V2BackgroundResultInbox.originDigest(plan.url)
        else { throw V2BackgroundTransferError.invalidAuthorization }
        let id=UUID()
        let context=V2NetworkWorkContext(service:"mediaProvider",priority:.background,kind:.byteTransfer,
            isRetry:V2NetworkWorkScope.context?.isRetry ?? false)
        let deadline=ContinuousClock.now.advanced(by:.seconds(min(15,max(0,grant.expiresAt.timeIntervalSinceNow))))
        let permit=try await scheduler.acquire(context,deadline:min(deadline,V2HTTPRequestDeadline.current ?? deadline))
        creating.insert(id);permits[id]=permit
        var taskID:Int?,file:URL?
        var installed=false
        do {
            try Task.checkCancellation();guard !closed else { throw V2BackgroundTransferError.closed }
            let destination=inbox.directory.appendingPathComponent("sources",isDirectory:true).appendingPathComponent(id.uuidString)
            try await Self.prepareSource(source:source,destination:destination,range:range,quotaRoot:root,protectionWriter:protectionWriter)
            file=destination
            try Task.checkCancellation()
            guard !closed else { throw V2BackgroundTransferError.closed }
            guard grant.expiresAt>Date() else { throw V2BackgroundTransferError.invalidAuthorization }
            var request=URLRequest(url:plan.url,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:30)
            request.httpMethod="PUT"
            for header in plan.headers { request.setValue(header.value,forHTTPHeaderField:header.name) }
            let identifier=try await driver.create(request:request,file:destination,mappingID:id);taskID=identifier
            try Task.checkCancellation();guard !closed else { throw V2BackgroundTransferError.closed }
            let mapping=V2BackgroundTaskMapping(id:id,sessionID:sessionID,jobID:job.id,activationID:activationID,sourceToken:id,
                taskIdentifier:identifier,partNumber:part,expectedBytes:plan.expectedByteCount,expiresAt:grant.expiresAt,originDigest:origin)
            // The newly created OS task is suspended until both sides are durably associated.
            try await store.installBackgroundMapping(mapping,resourceOwner:resourceOwner)
            installed=true;creating.remove(id);permits[id]=permit
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
            if let file { try? FileManager.default.removeItem(at:file) }
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
            repeat {
                self.reconciliationDirty=false
                try await self.performReconciliation()
            } while self.reconciliationDirty && !self.closed
        }
        reconciliation=work
        do { try await work.value; reconciliation=nil }
        catch { reconciliation=nil; throw error }
    }
    private func performReconciliation() async throws {
        guard !closed else { throw V2BackgroundTransferError.closed }
        let actual=await driver.tasks()
        guard actual.count<=64 else { await driver.cancelAndDrain(actual.map(\.identifier));throw V2BackgroundTransferError.capacityExceeded }
        if let protection=driver as? any V2BackgroundProtectedDataChecking,
           !(await protection.protectedDataAvailable()) { throw V2BackgroundTransferError.protectedDataUnavailable }
        let mappings=try await store.activeBackgroundMappings(session:sessionID)
        let byID=Dictionary(uniqueKeysWithValues:mappings.map { ($0.id,$0) })
        var orphans:[(Int,UUID)]=[]
        // Adopt all actual slots before cancelling or resuming any task or doing DB result work.
        for task in actual {
            let id=task.mappingID ?? UUID()
            if permits[id]==nil {
                permits[id]=try await scheduler.adoptExistingByteTransfer(id:id,context:.init(service:"mediaProvider",priority:.background,kind:.byteTransfer))
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
        for mapping in mappings {
            let task=actual.first { $0.mappingID==mapping.id && $0.identifier==mapping.taskIdentifier }
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
                try? FileManager.default.removeItem(at:inbox.directory.appendingPathComponent("sources").appendingPathComponent(mapping.sourceToken.uuidString))
            } else if task==nil {
                // Created/completed-but-unmapped or first-unlock inbox failures never mint a new job.
                if try await store.completeBackgroundMapping(mapping,result:nil) {
                    diagnostics?.record(V2BackgroundTransferMetric(result:nil))
                }
                await releasePermit(mapping.id)
                try? FileManager.default.removeItem(at:inbox.directory.appendingPathComponent("sources").appendingPathComponent(mapping.sourceToken.uuidString))
            } else if let task {
                if mapping.expiresAt<=Date() {
                    beginCancellation([mapping.id])
                    await driver.cancelAndDrain([task.identifier]);wakes.continuation.yield(())
                } else if task.suspended { try await driver.resume(task.identifier) }
            }
        }
        for result in receipts where byID[result.mappingID]==nil { try inbox.remove(result.mappingID) }
        let retained=Set(mappings.map(\.sourceToken)).union(creating)
        if try Self.removeOrphanSources(directory:inbox.directory.appendingPathComponent("sources"),retained:retained) {
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
                try? FileManager.default.removeItem(at:inbox.directory.appendingPathComponent("sources").appendingPathComponent(mapping.sourceToken.uuidString))
            }
        }
        for id in Array(permits.keys) { await releasePermit(id) }
        permits.removeAll();cancellationStarted.removeAll();wakes.continuation.finish()
        #if os(iOS)
        (driver as? V2NativeBackgroundSession)?.invalidateAfterDrain()
        #endif
    }
    /// Returns true when another bounded pass may be required.
    private nonisolated static func removeOrphanSources(directory:URL,retained:Set<UUID>) throws -> Bool {
        guard FileManager.default.fileExists(atPath:directory.path) else { return false }
        guard let files=FileManager.default.enumerator(at:directory,
            includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsSubdirectoryDescendants]) else { throw V2BackgroundTransferError.capacityExceeded }
        var removed=0,scanned=0
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        for case let file as URL in files {
            try Task.checkCancellation()
            if scanned==256 || ContinuousClock.now>=deadline {
                // Legitimate live sources are bounded by mappings plus creating.
                // Unexpected directory clutter cannot cause a zero-progress wake
                // loop or silently hide later orphan files. Pause visibly instead.
                guard removed>0 else { throw V2BackgroundTransferError.capacityExceeded }
                return true
            }
            scanned += 1
            guard let id=UUID(uuidString:file.lastPathComponent),!retained.contains(id) else { continue }
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at:file)
            removed += 1
            if removed==128 { return true }
        }
        return false
    }
    private nonisolated static func prepareSource(source:URL,destination:URL,range:V2ResourceByteRange,quotaRoot:URL,protectionWriter:any V2ResourceFileProtectionWriting) async throws {
        let work=Task.detached(priority:.utility) {
            try Self.copySource(source:source,destination:destination,range:range,quotaRoot:quotaRoot,protectionWriter:protectionWriter)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private nonisolated static func copySource(source:URL,destination:URL,range:V2ResourceByteRange,quotaRoot:URL,protectionWriter:any V2ResourceFileProtectionWriting) throws {
        try V2ResourceStagingBudget.register(directory:source.deletingLastPathComponent())
        try V2ResourceStagingBudget.withCopy(directory:quotaRoot,additionalBytes:range.byteCount,background:true) {
        try Self.sourcePreparation.withLock { _ in
            var existing:Int64=0
            if let entries=FileManager.default.enumerator(at:quotaRoot,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey]) {
                for case let file as URL in entries {
                    let values=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
                    if values.isRegularFile==true { existing += Int64(values.fileSize ?? 0) }
                    if existing>64*1_024*1_024 { throw V2BackgroundTransferError.capacityExceeded }
                }
            }
            guard range.byteCount<=8*1_024*1_024,existing<=64*1_024*1_024-range.byteCount else { throw V2BackgroundTransferError.capacityExceeded }
            let folder=destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try protectionWriter.apply(.untilFirstAuthentication,to:folder)
            var complete=false
            defer { if !complete { try? FileManager.default.removeItem(at:destination) } }
            try Data().write(to:destination,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
            var excluded=destination;var values=URLResourceValues();values.isExcludedFromBackup=true;try excluded.setResourceValues(values)
            try protectionWriter.apply(.untilFirstAuthentication,to:destination)
            let input=try FileHandle(forReadingFrom:source),output=try FileHandle(forWritingTo:destination)
            defer { try? input.close();try? output.close() }
            try input.seek(toOffset:UInt64(range.lowerBound))
            var remaining=range.byteCount
            while remaining>0 {
                try Task.checkCancellation()
                guard let data=try input.read(upToCount:Int(min(65_536,remaining))),!data.isEmpty else { throw V2ClientMediaTransferError.byteCountMismatch }
                try output.write(contentsOf:data);remaining -= Int64(data.count)
            }
            try output.synchronize();complete=true
        }
        }
    }
}
