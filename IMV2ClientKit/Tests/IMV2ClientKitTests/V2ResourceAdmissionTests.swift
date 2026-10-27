import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Account resource admission")
struct V2ResourceAdmissionTests {
    @Test func mixedJobsRetainQuotaAcrossPauseAndRestartButReplayIsFree() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = try fixture.open()
        let room = RoomID(uuid: UUID())
        var firstUpload: V2ResourcePreparedUpload?
        for _ in 0..<16 {
            let upload = try upload(room: room)
            _ = try await store.prepareMetadataResourceTransfer(id: upload.id, request: upload.request, localAssetID: upload.localAssetID)
            try await store.pauseResourceTransfer(id: upload.id, code: "network", retryAt: Date())
            if firstUpload == nil { firstUpload = upload }
        }
        let firstImportID = UUID(), firstImport = try importRequest(room: room)
        try await store.prepareResourceImport(id: firstImportID, request: firstImport)
        for _ in 0..<15 {
            let id = UUID()
            try await store.prepareResourceImport(id: id, request: importRequest(room: room))
            try await store.pauseResourceImport(id: id, needsAttention: true)
        }
        try await store.close()
        let reopened = try fixture.open()
        let same = try #require(firstUpload)
        _ = try await reopened.prepareMetadataResourceTransfer(id: same.id, request: same.request, localAssetID: same.localAssetID)
        try await reopened.prepareResourceImport(id: firstImportID, request: firstImport)
        let newID = UUID(), newRequest = try importRequest(room: room)
        await #expect(throws: V2ResourceJournalError.capacityExceeded) {
            try await reopened.prepareResourceImport(id: newID, request: newRequest)
        }
        #expect(try await reopened.resourceImport(id: newID) == nil)
        let cancelled = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: firstImport.operationID),
            mediaID: firstImport.targetMediaID, state: .cancelled, bindableUntil: nil)
        try await reopened.seedResourceImportStatus(cancelled, id: firstImportID)
        try await reopened.prepareResourceImport(id: newID, request: newRequest)
        let overflow = try upload(room: room)
        await #expect(throws: V2ResourceJournalError.capacityExceeded) {
            _ = try await reopened.prepareMetadataResourceTransfer(id: overflow.id, request: overflow.request, localAssetID: overflow.localAssetID)
        }
        try await reopened.close()
    }

    @Test func mixedAttachmentAdmissionRollsBackWholeIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = try fixture.open(), room = RoomID(uuid: UUID())
        for _ in 0..<31 { try await store.prepareResourceImport(id: UUID(), request: importRequest(room: room)) }
        let upload = try upload(room: room), importID = UUID(), request = try importRequest(room: room)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "two attachments", attachmentJobIDs: [importID, upload.id])
        await #expect(throws: V2ResourceJournalError.capacityExceeded) {
            try await store.freezeMetadataSendIntent(intent, resources: [upload], imports: [importID: request])
        }
        #expect(try await store.resourceImport(id: importID) == nil)
        #expect(try await store.resourceTransfer(id: upload.id) == nil)
        #expect(try await store.preparingSendIntents().isEmpty)
        // The rolled-back first attachment did not consume the last slot.
        try await store.prepareResourceImport(id: importID, request: request)
        try await store.close()
    }

    @Test func independentStoreConnectionsCannotOverAdmit() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let first = try fixture.open(), second = try fixture.open(), room = RoomID(uuid: UUID())
        for _ in 0..<31 { try await first.prepareResourceImport(id: UUID(), request: importRequest(room: room)) }
        let a = try importRequest(room: room), b = try importRequest(room: room)
        async let admittedA = admit(first, request: a)
        async let admittedB = admit(second, request: b)
        let results = try await [admittedA, admittedB]
        #expect(results.filter { $0 }.count == 1)
        try await first.close(); try await second.close()
    }

    @Test func readyImportCannotReactivateThroughLateProcessing() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = try fixture.open(), room = RoomID(uuid: UUID()), id = UUID()
        let request = try importRequest(room: room)
        try await store.prepareResourceImport(id: id, request: request)
        let ready = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID),
            mediaID: request.targetMediaID, state: .ready, bindableUntil: Date().addingTimeInterval(60))
        try await store.seedResourceImportStatus(ready, id: id)
        for _ in 0..<32 { try await store.prepareResourceImport(id: UUID(), request: importRequest(room: room)) }
        let late = try V2ResourceImportStatus(locator: ready.locator, mediaID: ready.mediaID, state: .processing, bindableUntil: nil)
        await #expect(throws: V2ResourceJournalError.conflict) { try await store.seedResourceImportStatus(late, id: id) }
        #expect(try await store.resourceImport(id: id)?.status?.state == .ready)
        try await store.close()
    }

    private func admit(_ store: GRDBV2LocalSyncStore, request: V2ResourceImportRequest) async throws -> Bool {
        do { try await store.prepareResourceImport(id: UUID(), request: request); return true }
        catch V2ResourceJournalError.capacityExceeded { return false }
    }

    private func upload(room: RoomID) throws -> V2ResourcePreparedUpload {
        let id = UUID()
        return try .init(id: id, request: .init(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(room), contentType: "image/png", byteCount: 3,
            checksum: .init(value: String(repeating: "a", count: 64))), localAssetID: .init(id))
    }

    private func importRequest(room: RoomID) throws -> V2ResourceImportRequest {
        try .init(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: room,
            messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
    }

    private struct Fixture {
        let directory: URL
        let binding = V2LocalInstallationBinding(value: UUID())
        let user = UserID(uuid: UUID())
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func open() throws -> GRDBV2LocalSyncStore {
            try .init(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: binding, userID: user)
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }
}
