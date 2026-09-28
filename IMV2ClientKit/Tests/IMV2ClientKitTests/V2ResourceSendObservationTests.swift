import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource send database observation")
struct V2ResourceSendObservationTests {
    @Test func pureImportProgressWakesBeforeAnyMessageHandoff() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try GRDBV2LocalSyncStore(databaseURL:root.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()),userID:.init(uuid:UUID()))
        let room=RoomID(uuid:UUID()),job=UUID(),events=AsyncStream<Void>.makeStream()
        let source=V2ResourceImportSource.message(location:.init(roomID:.init(uuid:UUID()),messageID:.init(uuid:UUID())),mediaID:.init(uuid:UUID()),variantID:nil)
        let request=try V2ResourceImportRequest(operationID:.init(uuid:UUID()),source:source,targetUsage:.messageAttachment(room),targetMediaID:.init(uuid:UUID()))
        try await store.prepareResourceImport(id:job,request:request)
        let intent=try V2SendIntent(id:UUID(),roomID:room,clientMessageID:.init(uuid:UUID()),text:"copy",attachmentJobIDs:[job])
        try await store.freezeSendIntent(intent)
        let observer=Task { for try await _ in store.resourceSendChanges(in:room) { events.continuation.yield(()) } }
        var seen=events.stream.makeAsyncIterator();_ = await seen.next()
        try await store.saveResourceImport(.init(locator:.init(home:.room(room),operationID:request.operationID),mediaID:request.targetMediaID,state:.copying,bindableUntil:nil),id:job)
        _ = await seen.next()
        #expect(try await store.preparingSendIntents(in:room)==[intent])
        #expect(try await store.dueOperationWork(now:Date(),kinds:[.sendMessage]).isEmpty)
        try await store.saveResourceImport(.init(locator:.init(home:.room(room),operationID:request.operationID),mediaID:request.targetMediaID,state:.ready,bindableUntil:Date().addingTimeInterval(60)),id:job)
        _ = await seen.next()
        #expect(try await store.preparingSendIntents(in:room)==[intent])
        observer.cancel();_ = await observer.result
    }
    @Test func databaseMutationWakesPageAndObserverCancellationLeavesFrozenIntent() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try GRDBV2LocalSyncStore(databaseURL:root.appendingPathComponent("db.sqlite"),installationBinding:.init(value:UUID()),userID:.init(uuid:UUID()))
        let room=RoomID(uuid:UUID()),events=AsyncStream<Void>.makeStream()
        let observer=Task {
            for try await _ in store.resourceSendChanges(in:room) { events.continuation.yield(()) }
        }
        var seen=events.stream.makeAsyncIterator()
        _ = await seen.next()
        let intent=try V2SendIntent(id:UUID(),roomID:room,clientMessageID:.init(uuid:UUID()),text:"frozen",attachmentJobIDs:[])
        try await store.freezeSendIntent(intent)
        _ = await seen.next()
        observer.cancel();_ = await observer.result
        #expect(try await store.preparingSendIntents(in:room)==[intent])
        _ = try await store.handOffSendIntent(intent.id)
        #expect(try await store.dueOperationWork(now:Date(),kinds:[.sendMessage]).count==1)
    }
}
