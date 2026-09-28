import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource preparation due scheduling")
struct V2ResourcePreparationTests {
    @Test func importCrashBudgetSurvivesRestartAndProcessingHasBoundedPolls() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-due-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        let id = UUID(), room = try RoomID(UUID().uuidString)
        let request = try importRequest(room: room)
        try await store.prepareResourceImport(id: id, request: request)
        let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        #expect(try await store.claimResourceImport(id, now: time))
        let deadline = try await store.resourceImportDeadline(id)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        #expect(try await restarted.resourceImport(id: id)?.attempts == 1)
        #expect(try await restarted.resourceImportDeadline(id) == deadline)
        for attempt in 2...5 { #expect(try await restarted.claimResourceImport(id, now: time.addingTimeInterval(Double(attempt)*10))) }
        #expect(try await restarted.dueResourceImports(now: time.addingTimeInterval(100)).isEmpty)
        try await restarted.retryResourceImport(id: id)
        let status = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .processing, bindableUntil: nil)
        for _ in 0..<60 { try await restarted.saveResourceImport(status, id: id) }
        #expect(try await restarted.resourceImport(id: id)?.attempts == 5)
        #expect(try await restarted.dueResourceImports(now: time.addingTimeInterval(10000)).isEmpty)
        try await restarted.close(); try await store.close()
    }
    @Test func databaseWakeHandsOffReadyDependencyAndCancellingScheduleDoesNotCancelIntent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("send-due-\(UUID()).sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()), userID: .init(uuid:UUID()))
        let id = UUID(), room = try RoomID(UUID().uuidString), request = try importRequest(room: room)
        try await store.prepareResourceImport(id: id, request: request)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(UUID().uuidString), text: "durable", attachmentJobIDs: [id])
        try await store.freezeSendIntent(intent)
        #expect(try await store.duePreparedSendIntents().isEmpty)
        // Exhaust import I/O admission, leaving the preparation owner idle until readiness changes.
        let time = Date()
        for attempt in 0..<5 { _ = try await store.claimResourceImport(id, now: time.addingTimeInterval(Double(attempt)*10)) }
        let signal = AsyncStream<Void>.makeStream()
        let activity = Task {
            try await store.runResourcePreparation {
                for value in try await store.duePreparedSendIntents() {
                    _ = try await store.handOffSendIntent(value.id)
                    signal.continuation.yield(())
                }
            }
        }
        let status = try V2ResourceImportStatus(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: .ready, bindableUntil: Date().addingTimeInterval(120))
        try await store.saveResourceImport(status, id: id)
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in signal.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let awakened = await group.next() ?? false
            #expect(awakened)
            group.cancelAll()
        }
        activity.cancel(); _ = await activity.result
        #expect(try await store.resourceSendPayloads().count == 1)
        #expect(try await store.resourceImport(id: id)?.cancellationRequested == false)
        try await store.close()
    }
    @Test func handoffFailureBudgetSurvivesRestartUntilExplicitUserRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-due-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        let intent = try V2SendIntent(id: UUID(), roomID: .init(UUID().uuidString), clientMessageID: .init(UUID().uuidString), text: "kept", attachmentJobIDs: [])
        try await store.freezeSendIntent(intent)
        for _ in 0..<5 { try await store.deferPreparedSendIntent(intent.id) }
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        #expect(try await restarted.preparedSendRequiresAttention(intent.id))
        #expect(try await restarted.duePreparedSendIntents(now: Date().addingTimeInterval(3600)).isEmpty)
        #expect(try await restarted.preparingSendIntents() == [intent])
        try await restarted.retryPreparedSendIntent(intent.id)
        #expect(try await restarted.duePreparedSendIntents() == [intent])
        try await restarted.close(); try await store.close()
    }

    @Test func userRetryAfterColdStartPreservesServerCooldownForImportAndUpload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-due-\(UUID()).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID()), now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let cooldown = now.addingTimeInterval(10000)
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        let id = UUID(), room = try RoomID(UUID().uuidString)
        try await store.prepareResourceImport(id: id, request: importRequest(room: room))
        _ = try await store.claimResourceImport(id, now: now)
        try await store.pauseResourceImport(id: id, retryNotBefore: cooldown)
        let uploadID = UUID(), owner = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uploadID.uuidString), mediaID: .init(uploadID.uuidString), usage: .userAvatar, contentType: "image/png", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64)))
        _ = try await store.prepareResourceTransfer(id: uploadID, request: request, localFileToken: uploadID.uuidString)
        _ = try await store.claimResourceStep(id: uploadID, owner: owner, now: now)
        try await store.failResourceStep(id: uploadID, owner: owner, code: "transport", retryAt: nil, serverRetryNotBefore: cooldown)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: .init(uuid:UUID(uuidString:"12345678-1234-1234-1234-123456789012")!))
        try await restarted.retryResourceImport(id: id)
        try await restarted.retryResourceTransfer(id: uploadID)
        #expect(try await restarted.resourceImport(id: id)?.retryAt == cooldown)
        #expect(try await restarted.resourceTransfer(id: uploadID)?.retryAt == cooldown)
        #expect(try await restarted.dueResourceImports(now: now.addingTimeInterval(100)).isEmpty)
        #expect(try await restarted.dueResourceTransfers(now: now.addingTimeInterval(100)).isEmpty)
        try await restarted.close(); try await store.close()
    }

    private func importRequest(room: RoomID) throws -> V2ResourceImportRequest {
        try .init(operationID: .init(UUID().uuidString), source: .message(location: .init(roomID: room, messageID: .init(UUID().uuidString)), mediaID: .init(UUID().uuidString), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(UUID().uuidString))
    }
}
