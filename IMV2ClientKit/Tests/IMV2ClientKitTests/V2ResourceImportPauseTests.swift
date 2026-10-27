import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Durable local import follow-up pause", .timeLimit(.minutes(1)))
struct V2ResourceImportPauseTests {
    @Test func offlinePauseSurvivesReopenAndContinuePreservesRequestAndServerFloor() async throws {
        let f = try await Fixture()
        try await f.center.pauseTransfer(.serverImport(f.id))
        #expect(try await f.store.dueResourceImports(now: .distantFuture).isEmpty)
        #expect(try await f.store.resourcePreparationSchedule().nextAttemptAt() == nil)
        #expect(try await f.store.claimResourceImport(f.id, owner: UUID(), now: .distantFuture) == false)
        let paused = try #require(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first)
        #expect(paused.phase == .paused && paused.actions == [.resume, .cancel])
        let floor = Date().addingTimeInterval(3600).timeIntervalSince1970
        try await f.store.databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET server_retry_not_before=? WHERE job_id=?", arguments: [floor, f.id.uuidString]) }
        await f.center.close(); try await f.store.close()
        let store = try GRDBV2LocalSyncStore(databaseURL: f.root.appending(path: "V2.sqlite"), installationBinding: f.binding, userID: f.user)
        let center = try await V2ResourceCenter.make(scope: f.scope, store: store)
        #expect(try await store.resourceImport(id: f.id)?.control == .pause)
        #expect(try await store.pendingResourceSendSnapshot(in: f.room, page: 0).preparing.first?.isUserPaused == true)
        try await center.resumeTransfer(.serverImport(f.id))
        let resumed = try #require(try await store.resourceImport(id: f.id))
        #expect(resumed.control == .run && resumed.request == f.request && resumed.status == nil)
        #expect(resumed.retryAt.timeIntervalSince1970 == floor && resumed.attempts == 0)
        #expect(try await store.dueResourceImports().isEmpty)
        await center.close(); try await store.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test func activeRequestRetainsOwnerUntilActualReturnAndLateCopyingCannotClearPause() async throws {
        let f = try await Fixture(), owner = UUID()
        #expect(try await f.store.claimResourceImport(f.id, owner: owner))
        try await f.center.pauseTransfer(.serverImport(f.id))
        let pausing = try #require(try await f.store.managedResourceTransfers(.init(group: .active)).entries.first)
        #expect(pausing.phase == .pausing && !pausing.actions.contains(.resume))
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(.serverImport(f.id)) }
        let copying = try f.status(.copying)
        try await f.store.saveResourceImport(copying, id: f.id, owner: owner)
        #expect(try await f.store.resourceImport(id: f.id)?.control == .pause)
        try await f.store.releaseResourceImportExecution(f.id, owner: owner)
        #expect(try await f.store.managedResourceTransfers(.init(group: .attention)).entries.first?.phase == .paused)
        #expect(try await f.store.dueResourceImports(now: .distantFuture).isEmpty)
        try await f.center.resumeTransfer(.serverImport(f.id))
        let continued = try #require(try await f.store.resourceImport(id: f.id))
        #expect(continued.status?.locator == copying.locator && continued.request == f.request)
        #expect(try await f.store.dueResourceImports().map(\.id) == [f.id])
        try await f.close()
    }

    @Test func cancellationSupersedesLocalPauseWithoutReactivatingItsMessage() async throws {
        let f = try await Fixture()
        try await f.center.pauseTransfer(.serverImport(f.id))
        try await f.center.cancelPreparation(try await f.center.planPreparationCancellation(.serverImport(f.id)))
        let cancelled = try #require(try await f.store.resourceImport(id: f.id))
        #expect(cancelled.cancellationRequested && cancelled.control == .run && cancelled.request == f.request)
        #expect(try await f.store.preparingSendIntents().isEmpty)
        #expect(try await f.store.pendingImportCancellations() == [f.id])
        #expect(try await f.store.dueResourceImports().map(\.id) == [f.id])
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(.serverImport(f.id)) }
        try await f.close()
    }

    @Test(arguments: [V2ResourceImportState.ready, .cancelled, .failed]) func authoritativeTerminalResultWinsAndStaleControlsAreRejected(state: V2ResourceImportState) async throws {
        let f = try await Fixture(), owner = UUID()
        #expect(try await f.store.claimResourceImport(f.id, owner: owner))
        try await f.center.pauseTransfer(.serverImport(f.id))
        try await f.store.saveResourceImport(f.status(state), id: f.id, owner: owner)
        try await f.store.releaseResourceImportExecution(f.id, owner: owner)
        let row = try #require(try await f.store.managedResourceTransfers(.init()).entries.first)
        // The resource cannot resume, but its still-preparing parent message
        // may be withdrawn even when the resource itself failed or cancelled.
        #expect(row.actions == (state == .ready ? [] : [.cancel]))
        #expect(row.phase == (state == .ready ? .completed : state == .cancelled ? .cancelled : .failed(.rejected)))
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.pauseTransfer(.serverImport(f.id)) }
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.resumeTransfer(.serverImport(f.id)) }
        #expect(try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0).preparing.first?.isUserPaused == false)
        try await f.close()
    }

    @Test func ordinaryRetryCannotClearUserPauseAndPrecanceledCallerCannotPause() async throws {
        let f = try await Fixture()
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await f.center.pauseTransfer(.serverImport(f.id))
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(try await f.store.resourceImport(id: f.id)?.control == .run)
        try await f.center.pauseTransfer(.serverImport(f.id))
        try await f.store.retryResourceImport(id: f.id)
        await #expect(throws: V2ResourceTransferManagementError.actionUnavailable) { try await f.center.retryTransfer(.serverImport(f.id)) }
        #expect(try await f.store.resourceImport(id: f.id)?.control == .pause)
        try await f.close()
    }

    @Test func changingOnlyImportControlWakesTheConversationSnapshot() async throws {
        let f = try await Fixture()
        do {
            var events = f.store.resourceSendChanges(in: f.room).makeAsyncIterator()
            #expect(try await events.next() != nil)
            try await f.center.pauseTransfer(.serverImport(f.id))
            #expect(try await events.next() != nil)
            #expect(try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0).preparing.first?.isUserPaused == true)
            try await f.center.resumeTransfer(.serverImport(f.id))
            #expect(try await events.next() != nil)
            #expect(try await f.store.pendingResourceSendSnapshot(in: f.room, page: 0).preparing.first?.isUserPaused == false)
        }
        try await f.close()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-pause-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), id = UUID()
        let binding = V2LocalInstallationBinding(value: UUID())
        let store: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        let scope: V2AccountStorageScope
        let request: V2ResourceImportRequest
        init() async throws {
            scope = .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache"))
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: binding, userID: user)
            center = try await .make(scope: scope, store: store)
            request = try .init(operationID: .init(uuid: UUID()), source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
            try await store.prepareResourceImport(id: id, request: request)
            try await store.freezeSendIntent(.init(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "frozen", attachmentJobIDs: [id]))
        }
        func status(_ state: V2ResourceImportState) throws -> V2ResourceImportStatus {
            try .init(locator: .init(home: .room(room), operationID: request.operationID), mediaID: request.targetMediaID, state: state, bindableUntil: state == .ready ? .distantFuture : nil)
        }
        func close() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
