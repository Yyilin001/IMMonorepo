import Foundation
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 durable group room creation outbox")
struct V2GroupRoomCommandOutboxTests {
    @Test("noninteger upload counts are rejected without truncation", arguments: [1.5, Double(Int64.max)])
    func nonintegerUploadedCount(count: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-group-upload-real-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: ScriptedGroupTransport(results: []))
            let command = try await engine.enqueueCreation(title: "upload recovery", deliveryMode: .standardFanout, initialMemberUserIDs: [.init(uuid: UUID()), .init(uuid: UUID())])
            let pool = await store.databasePool
            try await pool.write { try $0.execute(sql: "UPDATE v2_pending_group_room_creations SET uploaded_member_count = ?", arguments: [count]) }
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT typeof(uploaded_member_count) FROM v2_pending_group_room_creations") } == "real")
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.pendingGroupRoomCreations() }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.markGroupRoomCreationMembersUploaded(operationID: command.operationID, uploadedMemberCount: 2) }
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT uploaded_member_count FROM v2_pending_group_room_creations") } == count)
            try await store.resetGroupRoomCreationUploadProgress(operationID: command.operationID)
            try await store.markGroupRoomCreationMembersUploaded(operationID: command.operationID, uploadedMemberCount: 2)
            let recovered = try #require(try await store.pendingGroupRoomCreations().first)
            #expect(recovered.operationID == command.operationID && recovered.uploadedMemberCount == 2)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("upload progress rejects corrupt counts before advancing", arguments: [Int64.min, -1, 0, 1, 2, 3, Int64.max])
    func uploadedCountBounds(count: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-group-upload-count-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: ScriptedGroupTransport(results: []))
            let command = try await engine.enqueueCreation(title: "upload recovery", deliveryMode: .standardFanout, initialMemberUserIDs: [.init(uuid: UUID()), .init(uuid: UUID())])
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_pending_group_room_creations SET uploaded_member_count = ?", arguments: [count])
            }
            if count < 0 || count > 2 {
                await #expect(throws: V2ClientCommandError.commandConflict) { try await store.pendingGroupRoomCreations() }
                await #expect(throws: V2ClientCommandError.commandConflict) { try await store.markGroupRoomCreationMembersUploaded(operationID: command.operationID, uploadedMemberCount: 2) }
                #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT uploaded_member_count FROM v2_pending_group_room_creations") } == count)
                try await store.resetGroupRoomCreationUploadProgress(operationID: command.operationID)
            } else {
                #expect(try await store.pendingGroupRoomCreations().first?.uploadedMemberCount == Int(count))
            }
            try await store.markGroupRoomCreationMembersUploaded(operationID: command.operationID, uploadedMemberCount: 2)
            let recovered = try #require(try await store.pendingGroupRoomCreations().first)
            #expect(recovered.operationID == command.operationID && recovered.initialMemberUserIDs == command.initialMemberUserIDs)
            #expect(recovered.uploadedMemberCount == 2)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("group transitions reject invalid clocks and preserve their original phase", arguments: ["cancel", "resume"], [Double.nan, .infinity, -.infinity, -1, 0, 2_000])
    func transitionClockBounds(path: String, seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-group-transition-clock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: ScriptedGroupTransport(results: []), now: { Date(timeIntervalSince1970: 1_000) })
            let command = try await engine.enqueueCreation(title: "clock recovery", deliveryMode: .standardFanout, initialMemberUserIDs: [])
            if path == "resume" { try await store.beginCancellingGroupRoomCreation(operationID: command.operationID, now: Date(timeIntervalSince1970: 1_000)) }
            let before = try await store.pendingGroupRoomCreations()
            func transition(at date: Date) async throws {
                if path == "cancel" { try await store.beginCancellingGroupRoomCreation(operationID: command.operationID, now: date) }
                else { try await store.resumeGroupRoomCreationAfterCancellationRefusal(operationID: command.operationID, now: date) }
            }
            if seconds.isFinite {
                try await transition(at: Date(timeIntervalSince1970: seconds))
            } else {
                await #expect(throws: V2ClientCommandError.commandConflict) { try await transition(at: Date(timeIntervalSince1970: seconds)) }
                #expect(try await store.pendingGroupRoomCreations() == before)
                try await transition(at: Date(timeIntervalSince1970: 1_000))
            }
            let updated = try #require(try await store.pendingGroupRoomCreations().first)
            #expect(updated.operationID == command.operationID)
            #expect(updated.nextAttemptAt == Date(timeIntervalSince1970: seconds.isFinite ? seconds : 1_000))
            #expect(updated.state == (path == "cancel" ? .cancelling : .finalizing))
            if path == "cancel" {
                try await store.markGroupRoomCreationCancelled(operationID: command.operationID)
                #expect(try await store.pendingGroupRoomCreations().first?.state == .cancelled)
            } else {
                let room = RoomID(uuid: UUID())
                try await store.markGroupRoomCreationAcknowledged(operationID: command.operationID, roomID: room)
                #expect(try await store.pendingGroupRoomCreations().first?.createdRoomID == room)
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("retry survives a local-store restart and keeps the original operation")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-group-create-\(UUID().uuidString).sqlite")
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let member = try UserID("00000000-0000-0000-0000-000000000702")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000703")
        let transport = ScriptedGroupTransport(results: [.retryableFailure, .created(roomID)])
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000704")!)
        let first = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let firstEngine = V2GroupRoomCommandOutboxEngine(store: first, transport: transport, makeUUID: { operation }, now: { started })

        let command = try await firstEngine.enqueueCreation(title: " 项目群 ", deliveryMode: .standardFanout, initialMemberUserIDs: [member])
        #expect(command.title == "项目群")
        #expect(try await firstEngine.flushOnce() == .retryScheduled(command.operationID))
        let retried = try #require(await first.pendingGroupRoomCreations().first)
        #expect(retried.attemptCount == 1)

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2GroupRoomCommandOutboxEngine(store: restarted, transport: transport, now: { started.addingTimeInterval(1) })
        var restartResult: V2GroupRoomCreationFlushResult = .idle
        for _ in 0 ..< 4 {
            restartResult = try await restartedEngine.flushOnce()
            if case .acknowledged = restartResult { break }
        }
        #expect(restartResult == .acknowledged(command.operationID, roomID: roomID))
        let complete = try #require(await restarted.pendingGroupRoomCreations().first)
        #expect(complete.state == .acknowledged)
        #expect(complete.createdRoomID == roomID)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("terminal server validation failure is not retried")
    func terminalFailureIsNotRetried() async throws {
        let binding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!)
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-group-rejected-\(UUID().uuidString).sqlite"), installationBinding: binding)
        let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: ScriptedGroupTransport(results: [.rejected]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000706")! }, now: Date.init)
        let command = try await engine.enqueueCreation(title: "项目群", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        #expect(try await engine.flushOnce() == .rejected(command.operationID, code: "INVALID_ARGUMENT"))
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("重启后重复提交相同待建群意图会复用原操作")
    func duplicatePendingCreationReusesTheOriginalOperationAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "im-v2-group-reuse-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let firstOperation = UUID(uuidString: "00000000-0000-0000-0000-000000000707")!
        let firstEngine = V2GroupRoomCommandOutboxEngine(
            store: firstStore,
            transport: ScriptedGroupTransport(results: []),
            makeUUID: { firstOperation }
        )

        let original = try await firstEngine.enqueueCreation(title: " 项目群 ", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let restartedEngine = V2GroupRoomCommandOutboxEngine(
            store: restartedStore,
            transport: ScriptedGroupTransport(results: [])
        )
        let reused = try await restartedEngine.enqueueCreation(title: "项目群", deliveryMode: .standardFanout, initialMemberUserIDs: [])

        #expect(reused.operationID == original.operationID)
        let pending = try await restartedStore.pendingGroupRoomCreations()
        #expect(pending.count == 1)
    }

    @Test("5000 人建群以受限页面断点续传，不产生超帧请求")
    func fiveThousandMemberCreationUploadsInBoundedPages() async throws {
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000005000")!
        let roomID = try RoomID("00000000-0000-0000-0000-000000005001")
        let members = try (1 ... 5_000).map { index in
            try UserID("00000000-0000-0000-0000-\(String(format: "%012d", index))")
        }
        let store = try GRDBV2LocalSyncStore(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-group-pages-\(UUID().uuidString).sqlite"),
            installationBinding: .init(value: UUID())
        )
        let transport = ScriptedGroupTransport(results: [.created(roomID)])
        let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, makeUUID: { operation }, now: Date.init)
        let command = try await engine.enqueueCreation(title: "大群", deliveryMode: .standardFanout, initialMemberUserIDs: members)
        // One scheduler quantum performs exactly one authenticated step:
        // prepare, one bounded member page, or finalize.
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
        for _ in 0 ..< 8 { #expect(try await engine.flushOnce() == .retryScheduled(command.operationID)) }
        #expect(try #require(await store.pendingGroupRoomCreations().first).uploadedMemberCount == 4_096)
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
        #expect(try await engine.flushOnce() == .acknowledged(command.operationID, roomID: roomID))
    }

    @Test("过期草稿会从第零页安全恢复上传")
    func expiredDraftResetsTheDurableUploadCursor() async throws {
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000005100")!
        let roomID = try RoomID("00000000-0000-0000-0000-000000005101")
        let members = try (1 ... 5_000).map { index in
            try UserID("00000000-0000-0000-0000-\(String(format: "%012d", index + 10_000))")
        }
        let store = try GRDBV2LocalSyncStore(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-group-expiry-\(UUID().uuidString).sqlite"),
            installationBinding: .init(value: UUID())
        )
        let transport = ScriptedGroupTransport(results: [.created(roomID)])
        let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, makeUUID: { operation }, now: Date.init)
        let command = try await engine.enqueueCreation(title: "租期恢复", deliveryMode: .standardFanout, initialMemberUserIDs: members)
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
        for _ in 0 ..< 8 { #expect(try await engine.flushOnce() == .retryScheduled(command.operationID)) }
        #expect(try #require(await store.pendingGroupRoomCreations().first).uploadedMemberCount == 4_096)

        await transport.expireDraft()
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
        var resumed: V2GroupRoomCreationFlushResult = .idle
        for _ in 0 ..< 16 {
            resumed = try await engine.flushOnce()
            if case .acknowledged = resumed { break }
        }
        guard case .acknowledged(let returnedOperation, let returnedRoomID) = resumed else {
            Issue.record("expected expiry recovery to finish on the next bounded flush; got \(resumed)")
            return
        }
        #expect(returnedOperation == command.operationID)
        #expect(returnedRoomID == roomID)
        #expect(try #require(await store.pendingGroupRoomCreations().first).uploadedMemberCount == 5_000)
    }

    @Test("取消先持久化，重连后不会复活建群意图")
    func cancellationIsDurableAndTerminal() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-group-cancel-\(UUID().uuidString).sqlite"),
            installationBinding: .init(value: UUID())
        )
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000005200")!
        let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: ScriptedGroupTransport(results: []), makeUUID: { operation }, now: Date.init)
        let command = try await engine.enqueueCreation(title: "取消群", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        try await engine.requestCancellation(operationID: command.operationID)
        #expect(try await engine.flushOnce() == .cancelled(command.operationID))
        #expect(try #require(await store.pendingGroupRoomCreations().first).state == .cancelled)
        #expect(try await engine.flushOnce() == .idle)
    }

    @Test("冻结后的取消持久化为创建中，并在重启后恢复同一操作")
    func frozenCancellationPersistsFinalizingCreationAcrossRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-group-cancel-frozen-\(UUID().uuidString).sqlite")
        let binding = V2LocalInstallationBinding(value: UUID())
        let store = try GRDBV2LocalSyncStore(
            databaseURL: url,
            installationBinding: binding
        )
        let operation = UUID(uuidString: "00000000-0000-0000-0000-000000005201")!
        let transport = ScriptedGroupTransport(results: [], rejectsCancellationAsFrozen: true)
        let engine = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, makeUUID: { operation }, now: Date.init)
        let command = try await engine.enqueueCreation(title: "冻结群", deliveryMode: .standardFanout, initialMemberUserIDs: [])
        try await engine.requestCancellation(operationID: command.operationID)

        #expect(try await engine.flushOnce() == .cancellationRefused(command.operationID))
        #expect(try #require(await store.pendingGroupRoomCreations().first).state == .finalizing)
        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        #expect(try #require(await restarted.pendingGroupRoomCreations().first).state == .finalizing)
        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
    }
}

private actor ScriptedGroupTransport: V2ClientGroupMessagingTransport {
    enum Result: Sendable { case retryableFailure, created(RoomID), rejected }
    private var results: [Result]
    private var received: [GroupRoomOperationID] = []
    private var stagedMemberCount = 0
    private var stagedTitle = ""
    private var expired = false
    private let rejectsCancellationAsFrozen: Bool

    init(results: [Result], rejectsCancellationAsFrozen: Bool = false) {
        self.results = results
        self.rejectsCancellationAsFrozen = rejectsCancellationAsFrozen
    }

    func beginGroupRoomCreation(operationID: GroupRoomOperationID, title: String) throws -> V2ClientGroupAudienceDraft {
        received.append(operationID)
        stagedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = results.first {
            switch first {
            case .retryableFailure:
                _ = results.removeFirst(); throw V2RealtimeTransportError.unexpectedResponse
            case .rejected:
                _ = results.removeFirst(); throw V2RealtimeTransportError.server(code: "INVALID_ARGUMENT", retryable: false, retryAfterSeconds: 0, currentRevision: 0)
            case .created: break
            }
        }
        return try .init(operationID: operationID, title: stagedTitle, stagedMemberCount: stagedMemberCount)
    }

    func appendGroupRoomCreationMembers(operationID: GroupRoomOperationID, memberUserIDs: [UserID]) throws -> V2ClientGroupAudienceDraft {
        if expired {
            expired = false
            throw V2RealtimeTransportError.server(code: "NOT_FOUND", retryable: false, retryAfterSeconds: 0, currentRevision: 0)
        }
        stagedMemberCount += memberUserIDs.count
        return try .init(operationID: operationID, title: "staged", stagedMemberCount: stagedMemberCount)
    }

    func finalizeGroupRoomCreation(operationID: GroupRoomOperationID) throws -> V2ClientGroupRoom {
        guard !results.isEmpty else { throw V2RealtimeTransportError.unexpectedResponse }
        switch results.removeFirst() {
        case .created(let roomID): return .init(roomID: roomID, title: stagedTitle, deliveryMode: .standardFanout, memberUserIDs: [], memberCount: UInt32(stagedMemberCount + 1), createdAt: .distantPast)
        case .retryableFailure: throw V2RealtimeTransportError.unexpectedResponse
        case .rejected: throw V2RealtimeTransportError.server(code: "INVALID_ARGUMENT", retryable: false, retryAfterSeconds: 0, currentRevision: 0)
        }
    }

    func cancelGroupRoomCreation(operationID _: GroupRoomOperationID) throws {
        if rejectsCancellationAsFrozen {
            throw V2RealtimeTransportError.server(code: "GROUP_CREATION_FROZEN", retryable: false, retryAfterSeconds: 0, currentRevision: 0)
        }
    }

    func expireDraft() { stagedMemberCount = 0; expired = true }

    func operationIDs() -> [GroupRoomOperationID] { received }
}
