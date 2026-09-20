import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxGroupCreatorTests {
    @Test("a cancelled cancellation call preserves the pending creation")
    func cancelledCancellationCall() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-cancel-creation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let runtime = V2ClientRuntime(connection: OfflineConnection(), activity: UnusedActivity())
        do {
            let outbox = V2GroupRoomCommandOutboxEngine(store: store, transport: CreationTransport(rejectOld: false))
            let pending = try await outbox.enqueueCreation(title: "new", capacityClass: .standard, initialMemberUserIDs: [.init(uuid: UUID())])
            let before = try await store.groupRoomCreations()
            #expect(before.count == 1 && before.first?.operationID == pending.operationID && before.first?.state == .pending)
            let creator = V2OutboxGroupConversationCreator(outbox: outbox, runtime: runtime)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await creator.cancelConversationCreation(operationID: pending.operationID.rawValue)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.groupRoomCreations() == before)
            #expect(try await creator.cancelConversationCreation(operationID: pending.operationID.rawValue) == .cancelled)
            await runtime.stop()
            try await store.close()
        } catch {
            await runtime.stop()
            try? await store.close()
            throw error
        }
    }

    @Test("an older cancellation cannot complete or refuse the current cancellation", arguments: [false, true])
    func cancellationCorrelation(refuseOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancel-creation-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let runtime = V2ClientRuntime(connection: OfflineConnection(), activity: UnusedActivity())
        do {
            let transport = CreationTransport(rejectOld: false)
            let member = UserID(uuid: UUID())
            let olderOutbox = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
            let older = try await olderOutbox.enqueueCreation(title: "old", capacityClass: .standard, initialMemberUserIDs: [member])
            try await olderOutbox.requestCancellation(operationID: older.operationID)
            if refuseOld { await transport.refuseCancellation(older.operationID) }
            let outbox = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let current = try await outbox.enqueueCreation(title: "new", capacityClass: .standard, initialMemberUserIDs: [member])
            let creator = V2OutboxGroupConversationCreator(outbox: outbox, runtime: runtime)
            #expect(try await creator.cancelConversationCreation(operationID: current.operationID.rawValue) == .queuedForRetry)
            let commands = try await store.groupRoomCreations()
            #expect(commands.first { $0.operationID == current.operationID }?.state == .cancelling)
            #expect(commands.first { $0.operationID == older.operationID }?.state == (refuseOld ? .finalizing : .cancelled))
            #expect(try await outbox.flushOnce() == .cancelled(current.operationID))
            #expect(try await store.groupRoomCreations().first { $0.operationID == current.operationID }?.state == .cancelled)
            let next = try await outbox.enqueueCreation(title: "next", capacityClass: .standard, initialMemberUserIDs: [member])
            #expect(try await creator.cancelConversationCreation(operationID: next.operationID.rawValue) == .cancelled)
            await runtime.stop()
            try await store.close()
        } catch {
            await runtime.stop()
            try? await store.close()
            throw error
        }
    }

    @Test("an older group creation cannot supply the current room or rejection", arguments: [false, true])
    func creationCorrelation(rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-create-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let runtime = V2ClientRuntime(connection: OfflineConnection(), activity: UnusedActivity())
        do {
            let transport = CreationTransport(rejectOld: rejectOld)
            let member = UserID(uuid: UUID())
            let olderOutbox = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
            let older = try await olderOutbox.enqueueCreation(title: "old", capacityClass: .standard, initialMemberUserIDs: [member])
            let outbox = V2GroupRoomCommandOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let creator = V2OutboxGroupConversationCreator(outbox: outbox, runtime: runtime)
            let result = try await creator.createConversation(title: "new", initialMemberUserIDs: [member.rawValue])
            let commands = try await store.groupRoomCreations()
            let current = try #require(commands.first { $0.title == "new" })
            #expect(result == .queuedForRetry(operationID: current.operationID.rawValue))
            #expect(current.state == .pending)
            #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
            for _ in 0..<2 { #expect(try await outbox.flushOnce() == .retryScheduled(current.operationID)) }
            #expect(try await outbox.flushOnce() == .acknowledged(current.operationID, roomID: transport.newRoom))
            await runtime.stop()
            try await store.close()
        } catch {
            await runtime.stop()
            try? await store.close()
            throw error
        }
    }
}

private actor CreationTransport: V2ClientGroupMessagingTransport {
    let rejectOld: Bool
    let newRoom = RoomID(uuid: UUID())
    private var titles: [GroupRoomOperationID: String] = [:]
    private var refusedCancellation: GroupRoomOperationID?
    func refuseCancellation(_ operationID: GroupRoomOperationID) { refusedCancellation = operationID }
    init(rejectOld: Bool) { self.rejectOld = rejectOld }
    func beginGroupRoomCreation(operationID: GroupRoomOperationID, title: String) async throws -> V2ClientGroupAudienceDraft {
        titles[operationID] = title
        return try .init(operationID: operationID, title: title, stagedMemberCount: 0)
    }
    func appendGroupRoomCreationMembers(operationID: GroupRoomOperationID, memberUserIDs: [UserID]) async throws -> V2ClientGroupAudienceDraft {
        return try .init(operationID: operationID, title: try #require(titles[operationID]), stagedMemberCount: memberUserIDs.count)
    }
    func finalizeGroupRoomCreation(operationID: GroupRoomOperationID) async throws -> V2ClientGroupRoom {
        let title = try #require(titles[operationID])
        if rejectOld && title == "old" { throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil) }
        return .init(roomID: title == "new" ? newRoom : .init(uuid: UUID()), title: title, capacityClass: .standard, memberUserIDs: [], memberCount: 2, createdAt: Date(timeIntervalSince1970: 1_000))
    }
    func cancelGroupRoomCreation(operationID: GroupRoomOperationID) async throws {
        if operationID == refusedCancellation {
            throw V2RealtimeTransportError.server(code: "GROUP_CREATION_FROZEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        }
    }
}

private struct OfflineConnection: V2RealtimeSessionConnecting {
    func connect() async throws -> V2AuthenticatedClientSession { throw V2RealtimeTransportError.unexpectedResponse }
    func disconnect() async {}
}

private struct UnusedActivity: V2ClientRuntimeActivity {
    func synchronizeAfterConnection() async throws { Issue.record("offline runtime must not synchronize") }
    func flushDurableCommands() async throws { Issue.record("offline runtime must not flush") }
    func runAvailabilityLoop() async throws {}
    func runHeartbeatLoop() async throws {}
}
