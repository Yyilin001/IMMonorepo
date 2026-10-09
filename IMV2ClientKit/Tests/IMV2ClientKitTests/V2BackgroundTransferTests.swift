import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

// These cases exercise the process-wide disk budget and its aggregate counters.
// Running them concurrently lets another case change the very snapshot under test.
@Suite("Background task adoption and opaque handoff", .serialized)
struct V2BackgroundTransferTests {
    @Test(arguments: [false, true]) func stagingBusinessFailureDoesNotCountAsQuotaRejection(sameFailureType: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = V2ResourceStagingBudget.snapshot()
        #expect(throws: (any Error).self) {
            try V2ResourceStagingBudget.withCopy(directory: root, additionalBytes: 1) {
                if sameFailureType { throw V2ResourceStagingBudget.Failure.exceeded }
                throw V2ClientMediaTransferError.fileSystemFailure
            }
        }
        let after = V2ResourceStagingBudget.snapshot()
        #expect(after.capacityRejections == before.capacityRejections)
        #expect(after.rootLimitRejections == before.rootLimitRejections)
        #expect(after.lastObservedBytes != nil)
    }
    @Test func unknownStagingRootRejectsWithoutEnteringCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try V2ResourceStagingBudget.withCopy(directory: root, additionalBytes: 1) { }
        #expect(V2ResourceStagingBudget.snapshot().lastObservedBytes != nil)
        // The registered directory is replaced by a non-enumerable file.
        try FileManager.default.removeItem(at: root)
        try Data([1]).write(to: root)
        let before = V2ResourceStagingBudget.snapshot()
        var entered = false
        #expect(throws: V2ResourceStagingBudget.Failure.usageUnavailable) {
            try V2ResourceStagingBudget.withCopy(directory: root, additionalBytes: 1) { entered = true }
        }
        let after = V2ResourceStagingBudget.snapshot()
        #expect(!entered && after.lastObservedBytes == nil)
        #expect(after.unavailableUsageRejections == before.unavailableUsageRejections + 1)
        #expect(after.capacityRejections == before.capacityRejections)
        #expect(after.observedPeakBytes == before.observedPeakBytes)
    }
    @Test(arguments: [false, true]) func stagingBudgetCountsSourceAndOSCopyAcrossDirectories(backgroundFirst: Bool) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let originals=root.appendingPathComponent("originals"),background=root.appendingPathComponent("background")
        let sources=background.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at:originals,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:sources,withIntermediateDirectories:true)
        let original=originals.appendingPathComponent("source"),copy=sources.appendingPathComponent(UUID().uuidString)
        try Data().write(to:original);try Data().write(to:copy)
        let a=try FileHandle(forWritingTo:original),b=try FileHandle(forWritingTo:copy)
        try a.truncate(atOffset:400*1024*1024);try b.truncate(atOffset:50*1024*1024)
        try a.close();try b.close()
        try V2ResourceStagingBudget.register(directory:originals)
        // The same source is visible from an ordinary root and the background
        // root. Registration order must not discard its OS-copy reservation.
        if backgroundFirst { try V2ResourceStagingBudget.register(directory:background,background:true) }
        try V2ResourceStagingBudget.register(directory:sources)
        if !backgroundFirst { try V2ResourceStagingBudget.register(directory:background,background:true) }
        // 400 MiB originals + 50 MiB source + 50 MiB conservative system copy.
        #expect(throws:V2ResourceStagingBudget.Failure.exceeded) {
            try V2ResourceStagingBudget.withCopy(directory:background,additionalBytes:8*1024*1024,background:true) { }
        }
        try FileManager.default.removeItem(at:copy)
        try V2ResourceStagingBudget.withCopy(directory:background,additionalBytes:8*1024*1024,background:true) { }
    }
    @Test func simultaneousBackgroundCopiesCannotOverbookGlobalBudget() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let originals=root.appendingPathComponent("originals"),background=root.appendingPathComponent("background"),sources=background.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at:originals,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:sources,withIntermediateDirectories:true)
        let original=originals.appendingPathComponent("source");try Data().write(to:original)
        let file=try FileHandle(forWritingTo:original);try file.truncate(atOffset:480*1024*1024);try file.close()
        try V2ResourceStagingBudget.register(directory:originals)
        let copies=(0..<2).map { _ in Task.detached { () -> Bool in
            do {
                try V2ResourceStagingBudget.withCopy(directory:background,additionalBytes:12*1024*1024,background:true) {
                    let copy=sources.appendingPathComponent(UUID().uuidString);try Data().write(to:copy)
                    let handle=try FileHandle(forWritingTo:copy);try handle.truncate(atOffset:12*1024*1024);try handle.close()
                }
                return true
            } catch { return false }
        } }
        var admitted=0
        for copy in copies { if await copy.value { admitted += 1 } }
        #expect(admitted==1)
    }
    @Test func stableSessionSurvivesAccountStoreRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let binding=V2LocalInstallationBinding(value:UUID()),url=root.appendingPathComponent("db.sqlite")
        let first=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding)
        let id=try await first.backgroundSessionID()
        let restarted=try GRDBV2LocalSyncStore(databaseURL:url,installationBinding:binding)
        #expect(try await restarted.backgroundSessionID()==id)
    }
    @Test func orphanAdoptionRetainsSlotUntilActualDrain() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try GRDBV2LocalSyncStore(databaseURL:root.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()))
        let driver=BackgroundDriver(tasks:[.init(identifier:1,mappingID:UUID())])
        let scheduler=V2AccountWorkScheduler(configuration:.init(byteTransferLimit:1)),diagnostics=V2NetworkDiagnostics()
        let coordinator=try V2BackgroundTransferCoordinator(sessionID:UUID(),activationID:UUID(),store:store,scheduler:scheduler,driver:driver,root:root,diagnostics:diagnostics)
        let initTask=Task { try await coordinator.initialize() }
        await driver.waitForDrain()
        #expect(await scheduler.snapshot().active==1)
        #expect(diagnostics.snapshot().backgrounds.isEmpty)
        let pending=Task { try await scheduler.acquire(.init(service:"other",kind:.byteTransfer)) }
        while await scheduler.snapshot().waiting==0 { await Task.yield() }
        #expect(await scheduler.snapshot().active==1)
        await driver.finishDrain()
        try await initTask.value
        let cancellation = diagnostics.snapshot().backgrounds.compactMap(\.cancellationToPermitRelease)
        #expect(cancellation.count == 1 && cancellation.allSatisfy { $0.isFinite && $0 >= 0 })
        let permit=try await pending.value
        #expect(await scheduler.snapshot().active==1)
        _ = await scheduler.release(permit)
        #expect(await driver.wakeInstalled)
        await coordinator.close()
        #expect(await scheduler.snapshot().active==0)
    }
    @Test(arguments:[(false,false),(true,false),(true,true)]) func missingSystemTaskReconcilesSameIdentityWithoutReadyProof(hasReceipt:Bool,lockedCompletion:Bool) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try GRDBV2LocalSyncStore(databaseURL:root.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()))
        let id=UUID(),owner=UUID(),sessionID=try await store.backgroundSessionID()
        let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),usage:.messageAttachment(.init(uuid:UUID())),contentType:"text/plain",byteCount:4,checksum:.init(value:String(repeating:"a",count:64)))
        _ = try await store.prepareResourceTransfer(id:id,request:request,localFileToken:id.uuidString)
        let session=try V2ResourceUploadSession(locator:.init(home:.room(.init(uuid:UUID())),sessionID:.init(uuid:UUID())),mediaID:request.mediaID,generation:1,state:.created,resourceState:.pending,expiresAt:Date().addingTimeInterval(600))
        try await store.saveResourceSession(session,for:id)
        _ = try await store.claimResourceStep(id:id,owner:owner,now:Date())
        let mapping=V2BackgroundTaskMapping(id:UUID(),sessionID:sessionID,jobID:id,activationID:UUID(),sourceToken:UUID(),taskIdentifier:7,partNumber:1,expectedBytes:4,expiresAt:Date().addingTimeInterval(600),originDigest:"origin")
        try await store.installBackgroundMapping(mapping,resourceOwner:owner)
        let inbox=try V2BackgroundResultInbox(root:root,sessionID:sessionID)
        let folder=inbox.directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let copy=folder.appendingPathComponent(mapping.sourceToken.uuidString)
        try Data([1,2,3,4]).write(to:copy)
        if hasReceipt { try inbox.write(.init(mappingID:mapping.id,taskIdentifier:7,statusCode:200,errorCode:nil,sentBytes:4,originDigest:"origin",receivedBytes:2)) }
        let driver=BackgroundDriver(tasks:lockedCompletion ? [.init(identifier:7,mappingID:mapping.id)] : []),scheduler=V2AccountWorkScheduler()
        let diagnostics=V2NetworkDiagnostics()
        let coordinator=try V2BackgroundTransferCoordinator(sessionID:sessionID,activationID:UUID(),store:store,scheduler:scheduler,driver:driver,root:root,diagnostics:diagnostics)
        try await coordinator.initialize()
        var activity:Task<Void,any Error>?
        if lockedCompletion {
            activity=Task { try await coordinator.run() }
            await driver.setProtection(false)
            await driver.completeSystemTask(7)
            for _ in 0..<30 { await Task.yield() }
            #expect(try await store.activeBackgroundMappings(session:sessionID).count==1)
            #expect(try inbox.results().count==1)
            #expect(await scheduler.snapshot().active==1)
            await driver.setProtection(true)
            for try await job in store.resourceTransferUpdates(id:id) { if job?.nextAction == .status { break } }
        }
        let restored=try #require(await store.resourceTransfer(id:id))
        #expect(restored.request.operationID==request.operationID && restored.request.mediaID==request.mediaID)
        #expect(restored.nextAction == .status && restored.stage != .ready)
        #expect(try await store.activeBackgroundMappings(session:sessionID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath:copy.path))
        #expect(try inbox.results().isEmpty)
        #expect(diagnostics.snapshot().backgroundRecorded == 1)
        let metric=try #require(diagnostics.snapshot().backgrounds.first)
        #expect(metric.completionObserved == hasReceipt)
        #expect(metric.bodyBytesSent == (hasReceipt ? 4 : nil))
        #expect(metric.bodyBytesReceived == (hasReceipt ? 2 : nil))
        activity?.cancel();_ = await activity?.result
        await coordinator.close()
        // A late duplicate callback/inbox delivery after account restart cannot
        // recount a tombstoned system task or turn status into Ready proof.
        try inbox.write(.init(mappingID:mapping.id,taskIdentifier:7,statusCode:200,errorCode:nil,
            sentBytes:4,originDigest:"origin",receivedBytes:2))
        let restarted=try V2BackgroundTransferCoordinator(sessionID:sessionID,activationID:UUID(),store:store,
            scheduler:scheduler,driver:driver,root:root,diagnostics:diagnostics)
        try await restarted.initialize()
        #expect(diagnostics.snapshot().backgroundRecorded == 1)
        #expect(try inbox.results().isEmpty)
        #expect(try await store.completeBackgroundMapping(mapping,result:nil) == false)
        await restarted.close()
    }
    @Test(arguments: [false, true]) func taskResumesOnlyAfterDurableMapAndCancellationPreservesOriginalJob(expiresWithoutCallback: Bool) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=try GRDBV2LocalSyncStore(databaseURL:root.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()))
        let source=root.appendingPathComponent("original");try Data([1,2,3,4]).write(to:source)
        let id=UUID(),owner=UUID(),sessionID=try await store.backgroundSessionID(),room=RoomID(uuid:UUID())
        let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),usage:.messageAttachment(room),contentType:"text/plain",byteCount:4,checksum:.init(value:String(repeating:"a",count:64)))
        _ = try await store.prepareResourceTransfer(id:id,request:request,localFileToken:id.uuidString)
        let session=try V2ResourceUploadSession(locator:.init(home:.room(room),sessionID:.init(uuid:UUID())),mediaID:request.mediaID,generation:1,state:.created,resourceState:.pending,expiresAt:Date().addingTimeInterval(600))
        try await store.saveResourceSession(session,for:id)
        let job=try #require(await store.claimResourceStep(id:id,owner:owner,now:Date()))
        let expiry=Date().addingTimeInterval(expiresWithoutCallback ? 1 : 300)
        let grant=try V2ResourceBackgroundAuthorization(id:UUID(),sessionID:session.locator.sessionID,generation:1,mediaID:request.mediaID,partNumber:1,issuedAt:Date(),expiresAt:expiry)
        let plan=try V2ResourceTransferPlan(mode:.httpPartPut,url:URL(string:"https://provider.invalid/signed-object")!,headers:[.init(name:"Content-Type",value:"text/plain")],expiresAt:expiry,expectedByteCount:4,byteRange:.init(lowerBound:0,upperBound:3),partNumber:1,backgroundAuthorization:grant)
        let driver=BackgroundEnqueueDriver(store:store,sessionID:sessionID),scheduler=V2AccountWorkScheduler(),writer=BackgroundProtectionRecorder()
        let coordinator=try V2BackgroundTransferCoordinator(sessionID:sessionID,activationID:UUID(),store:store,scheduler:scheduler,driver:driver,root:root.appendingPathComponent("background"),protectionWriter:writer)
        let recovery = expiresWithoutCallback ? Task { try await coordinator.run() } : nil
        try await coordinator.initialize()
        if expiresWithoutCallback {
            await driver.waitForInitialActivityScan()
            try await coordinator.cancel(jobID: UUID()) // Join the initial reconciliation before enqueue.
        }
        try await coordinator.enqueue(job:job,resourceOwner:owner,plan:plan,source:source)
        #expect(await driver.resumedAfterMapping)
        let copiedFile=try #require(await driver.copiedFile)
        #expect(writer.policy(at:copiedFile) == .untilFirstAuthentication)
        #expect(writer.policy(at:source) == nil)
        #expect(try await store.resourceTransfer(id:id)?.nextAction == .awaitingBackground)
        #expect(try await store.dueResourceTransfers().isEmpty)
        #expect(await scheduler.snapshot().active==1)
        if expiresWithoutCallback {
            // The driver emits no callbacks. Only enqueue's wake can install
            // the grant timer and drain this actual task at expiry.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !(await driver.tasks()).isEmpty { try Task.checkCancellation(); await Task.yield() }
                }
                group.addTask { try await Task.sleep(for: .seconds(5)); throw URLError(.timedOut) }
                defer { group.cancelAll() }; _ = try await group.next()
            }
        }
        _ = try await store.requestResourceCancellation(id:id)
        try await coordinator.cancel(jobID:id)
        let cancelled=try #require(await store.resourceTransfer(id:id))
        #expect(cancelled.cancellationRequested && cancelled.nextAction == .cancel)
        #expect(cancelled.request.operationID==request.operationID)
        #expect(await scheduler.snapshot().active==0)
        #expect(try Data(contentsOf:source)==Data([1,2,3,4]))
        await coordinator.close()
        recovery?.cancel(); _ = await recovery?.result
    }
    @Test func failedProtectionWriteLeavesNoReceiptToMistakeForProtectedHandoff() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let inbox=try V2BackgroundResultInbox(root:root,sessionID:UUID(),protectionWriter:RejectResultProtection())
        #expect(throws:V2BackgroundTransferError.protectedDataUnavailable) {
            try inbox.write(.init(mappingID:UUID(),taskIdentifier:1,statusCode:200,errorCode:nil,sentBytes:1))
        }
        #expect(try inbox.results().isEmpty)
    }
    @Test func opaqueInboxIsBoundedAndContainsNoEndpointMaterial() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let inbox=try V2BackgroundResultInbox(root:root,sessionID:UUID())
        let id=UUID(),result=V2BackgroundTransferResult(mappingID:id,taskIdentifier:9,statusCode:200,errorCode:nil,sentBytes:32,originDigest:V2BackgroundResultInbox.originDigest(URL(string:"https://provider.example/path?secret=token")))
        try inbox.write(result)
        #expect(try inbox.results()==[result])
        let data=try Data(contentsOf:inbox.directory.appendingPathComponent(id.uuidString+".result"))
        let text=String(decoding:data,as:UTF8.self)
        #expect(!text.contains("provider.example"));#expect(!text.contains("token"));#expect(data.count<2048)
        try inbox.remove(id);#expect(try inbox.results().isEmpty)
        #expect(V2BackgroundResultInbox.originDigest(URL(string:"http://provider.example"))==nil)
    }
}
private actor BackgroundDriver:V2BackgroundSessionDriving,V2BackgroundProtectedDataChecking {
    private var available=true
    private var wake:@Sendable () async -> Void = {}
    private var actual:[V2BackgroundSystemTask]
    private var drain:CheckedContinuation<Void,Never>?
    private var entered=false
    private(set) var wakeInstalled=false
    init(tasks:[V2BackgroundSystemTask]) { actual=tasks }
    func tasks() -> [V2BackgroundSystemTask] { actual }
    func create(request:URLRequest,file:URL,mappingID:UUID) throws -> Int { throw V2BackgroundTransferError.unsupported }
    func resume(_ identifier:Int) {}
    func installWake(_ wake:@escaping @Sendable () async -> Void) { wakeInstalled=true;self.wake=wake }
    func protectedDataAvailable() -> Bool { available }
    func setProtection(_ available:Bool) async { self.available=available;await wake() }
    func completeSystemTask(_ id:Int) async { actual.removeAll {$0.identifier==id};await wake() }
    func cancelAndDrain(_ identifiers:[Int]) async {
        guard !identifiers.isEmpty else { return }
        entered=true
        await withCheckedContinuation { drain=$0 }
        actual.removeAll { identifiers.contains($0.identifier) }
    }
    func waitForDrain() async { while !entered { await Task.yield() } }
    func finishDrain() { drain?.resume();drain=nil }
}

private actor BackgroundEnqueueDriver:V2BackgroundSessionDriving {
    private let store:GRDBV2LocalSyncStore
    private let sessionID:UUID
    private var actual:[V2BackgroundSystemTask]=[]
    private(set) var resumedAfterMapping=false
    private(set) var copiedFile:URL?
    init(store:GRDBV2LocalSyncStore,sessionID:UUID) { self.store=store;self.sessionID=sessionID }
    private var scans = 0
    func tasks() -> [V2BackgroundSystemTask] { scans += 1; return actual }
    func waitForInitialActivityScan() async { while scans < 2 { await Task.yield() } }
    func create(request:URLRequest,file:URL,mappingID:UUID) throws -> Int {
        #expect(request.value(forHTTPHeaderField:"Authorization")==nil)
        #expect(try Data(contentsOf:file)==Data([1,2,3,4]))
        copiedFile=file
        actual=[.init(identifier:10,mappingID:mappingID,suspended:true)];return 10
    }
    func resume(_ identifier:Int) async throws {
        let mappings=try await store.activeBackgroundMappings(session:sessionID)
        resumedAfterMapping=mappings.contains {$0.taskIdentifier==identifier}
        guard resumedAfterMapping else { throw V2BackgroundTransferError.mappingConflict }
        actual=actual.map { .init(identifier:$0.identifier,mappingID:$0.mappingID,suspended:false) }
    }
    func cancelAndDrain(_ identifiers:[Int]) { actual.removeAll { identifiers.contains($0.identifier) } }
    func installWake(_ wake:@escaping @Sendable () async -> Void) {}
}

private final class BackgroundProtectionRecorder:V2ResourceFileProtectionWriting {
    private let values=Mutex<[String:V2ResourceFileProtection]>([:])
    func apply(_ protection:V2ResourceFileProtection,to file:URL) { values.withLock { $0[file.path]=protection } }
    func policy(at file:URL) -> V2ResourceFileProtection? { values.withLock { $0[file.path] } }
}

private struct RejectResultProtection:V2ResourceFileProtectionWriting {
    func apply(_ protection:V2ResourceFileProtection,to file:URL) throws {
        if file.pathExtension=="result" { throw V2BackgroundTransferError.protectedDataUnavailable }
    }
}
