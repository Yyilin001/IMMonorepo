import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("Resource journal and frozen send intent")
struct V2ResourceJournalTests {
    @Test func frozenIntentSurvivesRestartAndHandsOffOnlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resource-journal-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let intent = try V2SendIntent(id: UUID(), roomID: .init(UUID().uuidString), clientMessageID: .init(UUID().uuidString), text: "immutable snapshot", attachmentJobIDs: [])
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        try await first.freezeSendIntent(intent)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try await restarted.preparingSendIntents() == [intent])
        #expect(try await restarted.handOffSendIntent(intent.id) == intent.clientMessageID)
        #expect(try await restarted.handOffSendIntent(intent.id) == intent.clientMessageID)
        #expect(try await restarted.pendingMessageCommands().count == 1)
        #expect(try await restarted.preparingSendIntents().isEmpty)
        await #expect(throws: V2ResourceJournalError.alreadyHandedOff) { try await restarted.cancelSendIntent(intent.id) }
    }

    @Test func importedResourceHandsOffNewIdentityAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-journal-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let room = try RoomID(UUID().uuidString), sourceRoom = try RoomID(UUID().uuidString), id = UUID()
        let source = V2ResourceImportSource.message(location: .init(roomID: sourceRoom, messageID: try .init(UUID().uuidString)), mediaID: try .init(UUID().uuidString), variantID: nil)
        let request = try V2ResourceImportRequest(operationID: .init(UUID().uuidString), source: source, targetUsage: .messageAttachment(room), targetMediaID: .init(UUID().uuidString))
        try await store.prepareResourceImport(id: id, request: request)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(UUID().uuidString), text: "copy", attachmentJobIDs: [id])
        try await store.freezeSendIntent(intent)
        await #expect(throws: V2ResourceJournalError.dependencyNotReady) { try await store.handOffSendIntent(intent.id) }
        let status = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .ready, bindableUntil: Date().addingTimeInterval(60))
        try await store.saveResourceImport(status, id: id)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        _ = try await restarted.handOffSendIntent(intent.id)
        let commands = try await restarted.pendingMessageCommands()
        #expect(commands.count == 1)
        #expect(commands.first?.media == [.init(mediaID: request.targetMediaID)])
        #expect(request.targetMediaID != source.mediaID)
    }

    @Test func changedComposerCannotOverwriteFrozenIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resource-frozen-\(UUID()).sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()))
        let intent = try V2SendIntent(id: UUID(), roomID: .init(UUID().uuidString), clientMessageID: .init(UUID().uuidString), text: "original", attachmentJobIDs: [])
        try await store.freezeSendIntent(intent)
        let changed = try V2SendIntent(id: intent.id, roomID: intent.roomID, clientMessageID: intent.clientMessageID, text: "edited", attachmentJobIDs: [])
        await #expect(throws: V2ResourceJournalError.conflict) { try await store.freezeSendIntent(changed) }
        #expect(try await store.preparingSendIntents() == [intent])
        try await store.cancelSendIntent(intent.id)
        await #expect(throws: V2ResourceJournalError.conflict) { try await store.handOffSendIntent(intent.id) }
        #expect(try await store.pendingMessageCommands().isEmpty)
    }
}

@Suite("Durable resource recovery")
struct V2ResourceRecoveryTests {
    @Test(arguments:[false,true]) func onlyPermanentClosureAllowsOneFrozenReplacementAndKeepsItsSourceFile(mixedImports:Bool) async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try GRDBV2LocalSyncStore(databaseURL:directory.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()))
        let room=RoomID(uuid:UUID()), jobID=UUID()
        let file=directory.appendingPathComponent(jobID.uuidString)
        try Data([1,2,3]).write(to:file)
        let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),usage:.messageAttachment(room),contentType:"text/plain",byteCount:3,checksum:.init(value:String(repeating:"b",count:64)))
        _ = try await store.prepareResourceTransfer(id:jobID,request:request,localFileToken:jobID.uuidString)
        let ready=try V2ResourceUploadSession(locator:.init(home:.room(room),sessionID:.init(uuid:UUID())),mediaID:request.mediaID,generation:1,state:.completed,resourceState:.ready,expiresAt:Date().addingTimeInterval(100),bindableUntil:Date().addingTimeInterval(100))
        try await store.saveResourceSession(ready,for:jobID)
        var attachmentIDs=[jobID]
        var originalImports:[V2ResourceImportRequest]=[]
        if mixedImports {
            for ordinal in 0..<2 {
                let importID=UUID()
                let imported=try V2ResourceImportRequest(operationID:.init(uuid:UUID()),
                    source:.message(location:.init(roomID:.init(uuid:UUID()),messageID:.init(uuid:UUID())),mediaID:.init(uuid:UUID()),variantID:nil),
                    targetUsage:.messageAttachment(room),targetMediaID:.init(uuid:UUID()))
                originalImports.append(imported)
                try await store.prepareResourceImport(id:importID,request:imported)
                try await store.saveResourceImport(.init(locator:.init(home:.room(room),operationID:imported.operationID),mediaID:imported.targetMediaID,state:.ready,bindableUntil:Date().addingTimeInterval(100)),id:importID)
                attachmentIDs.insert(importID,at:ordinal==0 ? 0 : 2)
            }
        }
        let intent=try V2SendIntent(id:UUID(),roomID:room,clientMessageID:.init(uuid:UUID()),text:"Frozen original text",
            mentions:[.user(.init(uuid:UUID()))],entities:[.init(offsetUTF16:0,lengthUTF16:6,kind:.bold)],
            replyTo:.init(messageID:.init(uuid:UUID())),attachmentJobIDs:attachmentIDs)
        try await store.freezeSendIntent(intent)
        _ = try await store.handOffSendIntent(intent.id)
        try await store.requireMessageOperationRecovery(intent.clientMessageID,now:Date())
        await #expect(throws:V2ResourceJournalError.conflict) { _ = try await store.replacePermanentlyClosedSendIntent(intent.id) }
        #expect(try await store.preparingSendIntents().isEmpty)
        try await store.completeMessageOperationRecovery(intent.clientMessageID,result:.closed)
        #expect(try await store.submittedSendIntents(in:room).first?.status == .closed)
        let replacementID=try await store.replacePermanentlyClosedSendIntent(intent.id)
        #expect(try await store.replacePermanentlyClosedSendIntent(intent.id)==replacementID)
        let pending=try await store.preparingSendIntents(in:room)
        let replacement=try #require(pending.first)
        #expect(pending.count==1 && replacement.id==replacementID)
        #expect(replacement.clientMessageID != intent.clientMessageID)
        #expect(replacement.text==intent.text && replacement.replyTo==intent.replyTo)
        #expect(replacement.mentions==intent.mentions && replacement.entities==intent.entities)
        #expect(replacement.attachmentJobIDs.count==attachmentIDs.count)
        let newJobID=replacement.attachmentJobIDs[mixedImports ? 1 : 0]
        let newJob=try #require(try await store.resourceTransfer(id:newJobID))
        #expect(newJob.request.mediaID != request.mediaID && newJob.request.operationID != request.operationID)
        #expect(newJob.request.checksum==request.checksum && newJob.localFileToken==jobID.uuidString)
        let engine=V2ResourceTransferEngine(store:store,control:ReadyResourceControl(ready:ready),executor:ForbiddenResourceExecutor(),directory:directory)
        try await engine.releaseAcceptedStaging()
        #expect(FileManager.default.fileExists(atPath:file.path))
        #expect(try await store.pendingMessageCommands().count==1)
        let newReady=try V2ResourceUploadSession(locator:.init(home:.room(room),sessionID:.init(uuid:UUID())),mediaID:newJob.request.mediaID,generation:1,state:.completed,resourceState:.ready,expiresAt:Date().addingTimeInterval(100),bindableUntil:Date().addingTimeInterval(100))
        try await store.saveResourceSession(newReady,for:newJobID)
        if mixedImports {
            await #expect(throws:V2ResourceJournalError.dependencyNotReady) { _ = try await store.handOffSendIntent(replacementID) }
            for (index,ordinal) in [0,2].enumerated() {
                let replacementJobID=replacement.attachmentJobIDs[ordinal]
                let imported=try #require(try await store.resourceImport(id:replacementJobID)).request
                #expect(imported.source==originalImports[index].source && imported.targetUsage==originalImports[index].targetUsage)
                #expect(imported.operationID != originalImports[index].operationID && imported.targetMediaID != originalImports[index].targetMediaID)
                try await store.saveResourceImport(.init(locator:.init(home:.room(room),operationID:imported.operationID),mediaID:imported.targetMediaID,state:.ready,bindableUntil:Date().addingTimeInterval(100)),id:replacementJobID)
            }
        }
        _ = try await store.handOffSendIntent(replacementID)
        let commands=try await store.pendingMessageCommands()
        let submitted=try #require(commands.first {$0.clientMessageID==replacement.clientMessageID})
        #expect(submitted.media[mixedImports ? 1 : 0].mediaID==newJob.request.mediaID)
        if mixedImports {
            for ordinal in [0,2] {
                #expect(submitted.media[ordinal].mediaID == (try await store.resourceImport(id:replacement.attachmentJobIDs[ordinal]))?.request.targetMediaID)
            }
        }
        try await engine.releaseAcceptedStaging()
        #expect(FileManager.default.fileExists(atPath:file.path))
        try await store.markMessageAccepted(clientMessageID:replacement.clientMessageID,messageID:.init(uuid:UUID()),roomSequence:1)
        try await engine.releaseAcceptedStaging()
        #expect(!FileManager.default.fileExists(atPath:file.path))
        await engine.close()
        try await store.close()
    }
    @Test func stagingAndCommandSurviveUnknownOutcomeUntilAcceptedCleanup() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try GRDBV2LocalSyncStore(databaseURL:directory.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()))
        let room=RoomID(uuid:UUID()), jobID=UUID()
        let file=directory.appendingPathComponent(jobID.uuidString)
        try Data([1,2,3]).write(to:file)
        let request=try V2ResourceUploadRequest(operationID:.init(uuid:UUID()),mediaID:.init(uuid:UUID()),usage:.messageAttachment(room),contentType:"text/plain",byteCount:3,checksum:.init(value:String(repeating:"a",count:64)))
        _ = try await store.prepareResourceTransfer(id:jobID,request:request,localFileToken:jobID.uuidString)
        let ready=try V2ResourceUploadSession(locator:.init(home:.room(room),sessionID:.init(uuid:UUID())),mediaID:request.mediaID,generation:1,state:.completed,resourceState:.ready,expiresAt:Date().addingTimeInterval(100),bindableUntil:Date().addingTimeInterval(100))
        try await store.saveResourceSession(ready,for:jobID)
        let intent=try V2SendIntent(id:UUID(),roomID:room,clientMessageID:.init(uuid:UUID()),text:"Retain the original",attachmentJobIDs:[jobID])
        try await store.freezeSendIntent(intent)
        _ = try await store.handOffSendIntent(intent.id)
        let engine=V2ResourceTransferEngine(store:store,control:ReadyResourceControl(ready:ready),executor:ForbiddenResourceExecutor(),directory:directory)
        try await engine.releaseAcceptedStaging()
        #expect(FileManager.default.fileExists(atPath:file.path))
        #expect(try await store.submittedSendIntents(in:room).first?.status == .pending)
        try await store.requireMessageOperationRecovery(intent.clientMessageID,now:Date())
        #expect(try await store.submittedSendIntents(in:room).first?.status == .confirmingOutcome)
        try await store.pruneTerminalCommands(olderThan:Date().addingTimeInterval(86_400))
        try await engine.releaseAcceptedStaging()
        #expect(FileManager.default.fileExists(atPath:file.path))
        #expect(try await store.pendingMessageCommands().count==1)
        try await store.completeMessageOperationRecovery(intent.clientMessageID,result:.accepted(.init(messageID:.init(uuid:UUID()),roomSequence:1)))
        #expect(try await store.submittedSendIntents(in:room).isEmpty)
        try await store.pruneTerminalCommands(olderThan:Date().addingTimeInterval(86_400))
        #expect(try await store.pendingMessageCommands().count==1)
        try await engine.releaseAcceptedStaging()
        #expect(!FileManager.default.fileExists(atPath:file.path))
        #expect(try await store.releasableResourceJobs().isEmpty)
        try await store.pruneTerminalCommands(olderThan:Date().addingTimeInterval(86_400))
        #expect(try await store.pendingMessageCommands().isEmpty)
        await engine.close()
        try await store.close()
    }
    @Test func newDefaultCapabilitiesDoNotRejectPersistedUploadRecovery() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try GRDBV2LocalSyncStore(databaseURL:directory.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()))
        let room=try RoomID(UUID().uuidString),existingID=UUID()
        let request=try V2ResourceUploadRequest(operationID:.init(UUID().uuidString),mediaID:.init(UUID().uuidString),usage:.messageAttachment(room),contentType:"text/plain",byteCount:3,checksum:.init(value:String(repeating:"a",count:64)))
        _ = try await store.prepareResourceTransfer(id:existingID,request:request,localFileToken:existingID.uuidString)
        let ready=try V2ResourceUploadSession(locator:.init(home:.room(room),sessionID:.init(UUID().uuidString)),mediaID:request.mediaID,generation:1,state:.completed,resourceState:.ready,expiresAt:Date().addingTimeInterval(100),bindableUntil:Date().addingTimeInterval(100))
        let cache=V2ResourceCapabilitiesCache(reader:ReducedResourceCapabilities())
        try await cache.refreshIfNeeded()
        let engine=V2ResourceTransferEngine(store:store,control:ReadyResourceControl(ready:ready),executor:ForbiddenResourceExecutor(),directory:directory,capabilities:cache)
        #expect(try await engine.prepare(id:existingID,request:request).id==existingID)
        let newID=UUID()
        await #expect(throws:V2ResourceCapabilityError.fileTooLarge(maximumBytes:1)) { _ = try await engine.prepare(id:newID,request:request) }
        #expect(try await store.resourceTransfer(id:newID)==nil)
        await engine.close()
    }
    @Test func finalizedResponseLostRecoversOriginalSessionWithoutUploadingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: binding)
        let jobID = UUID()
        let room = try RoomID(UUID().uuidString)
        let request = try V2ResourceUploadRequest(operationID: .init(UUID().uuidString), mediaID: .init(UUID().uuidString), usage: .messageAttachment(room), contentType: "text/plain", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
        _ = try await store.prepareResourceTransfer(id: jobID, request: request, localFileToken: jobID.uuidString)
        let locator = V2ResourceUploadLocator(home: .room(room), sessionID: try .init(UUID().uuidString))
        let processing = try V2ResourceUploadSession(locator: locator, mediaID: request.mediaID, generation: 1, state: .finalizing, resourceState: .scanning, expiresAt: Date().addingTimeInterval(100))
        try await store.saveResourceSession(processing, for: jobID)
        let ready = try V2ResourceUploadSession(locator: locator, mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready, expiresAt: Date().addingTimeInterval(100), bindableUntil: Date().addingTimeInterval(100))
        let control = ReadyResourceControl(ready: ready)
        let executor = ForbiddenResourceExecutor()
        let restarted = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: binding)
        let engine = V2ResourceTransferEngine(store: restarted, control: control, executor: executor, directory: directory)
        let result = try await engine.resume(id: jobID)
        #expect(result.request == request)
        #expect(result.session?.locator == locator)
        #expect(result.stage == .ready)
        #expect(await control.statusReads == [locator])
        await engine.close()
    }

    @Test func expiredDependencyCannotBeHandedOff() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("expired-resource-\(UUID()).sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()))
        let jobID = UUID(), room = try RoomID(UUID().uuidString)
        let request = try V2ResourceUploadRequest(operationID: .init(UUID().uuidString), mediaID: .init(UUID().uuidString), usage: .messageAttachment(room), contentType: "text/plain", byteCount: 3, checksum: .init(value: String(repeating: "b", count: 64)))
        _ = try await store.prepareResourceTransfer(id: jobID, request: request, localFileToken: jobID.uuidString)
        let ready = try V2ResourceUploadSession(locator: .init(home: .room(room), sessionID: .init(UUID().uuidString)), mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready, expiresAt: Date(), bindableUntil: Date().addingTimeInterval(-1))
        try await store.saveResourceSession(ready, for: jobID)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(UUID().uuidString), text: "", attachmentJobIDs: [jobID])
        try await store.freezeSendIntent(intent)
        await #expect(throws: V2ResourceJournalError.bindingExpired) { try await store.handOffSendIntent(intent.id) }
        #expect(try await store.pendingMessageCommands().isEmpty)
    }
}

private struct ReducedResourceCapabilities:V2ResourceCapabilityReading {
    func capabilities() throws -> V2ResourceCapabilities {
        try .init(uploadModes:[.httpPut],maximumBytes:1,allowedUsages:[.messageAttachment],maximumParts:0,backgroundTransfer:false)
    }
}

private actor ReadyResourceControl: V2ResourceUploadControlling {
    let ready: V2ResourceUploadSession
    var statusReads: [V2ResourceUploadLocator] = []
    init(ready: V2ResourceUploadSession) { self.ready = ready }
    func create(_ request: V2ResourceUploadRequest) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
    func status(_ locator: V2ResourceUploadLocator) async throws -> V2ResourceUploadSession { statusReads.append(locator); return ready }
    func target(_ session: V2ResourceUploadSession) async throws -> V2ResourceTransferPlan { throw V2ResourceJournalError.conflict }
    func finalize(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
    func cancel(_ session: V2ResourceUploadSession) async throws -> V2ResourceUploadSession { throw V2ResourceJournalError.conflict }
}
private struct ForbiddenResourceExecutor: V2ResourcePlanExecuting {
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws { throw V2ResourceJournalError.conflict }
}
