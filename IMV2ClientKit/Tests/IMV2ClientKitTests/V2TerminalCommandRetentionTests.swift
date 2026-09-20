import Foundation
import GRDB
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 terminal command retention")
struct V2TerminalCommandRetentionTests {
    @Test("expiration rejects a clock that cannot represent the retry age", arguments: [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude])
    func unrepresentableRetryWindow(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-retention-window-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: terminalRetentionInstallationBinding)
        do {
            let command = try pendingMessage(roomID: .init(uuid: UUID()), clientMessageID: UUID().uuidString, createdAt: 100)
            try await store.enqueue(command)
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.expireStalePendingCommands(now: Date(timeIntervalSince1970: seconds)) }
            #expect(try await store.pendingMessageCommands() == [command])
            try await store.expireStalePendingCommands(now: Date(timeIntervalSince1970: 1_000))
            #expect(try await store.pendingMessageCommands() == [command])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("invalid cleanup clocks preserve pending and terminal commands", arguments: ["expire", "prune"], [Double.nan, .infinity, -.infinity])
    func cleanupClockBounds(stage: String, seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-retention-clock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: terminalRetentionInstallationBinding)
        do {
            let room = RoomID(uuid: UUID())
            let old = try pendingMessage(roomID: room, clientMessageID: UUID().uuidString, createdAt: 100)
            let recent = try pendingMessage(roomID: room, clientMessageID: UUID().uuidString, createdAt: 1_100)
            let terminal = try pendingMessage(roomID: room, clientMessageID: UUID().uuidString, createdAt: 50)
            for command in [old, recent, terminal] { try await store.enqueue(command) }
            try await store.rejectMessage(clientMessageID: terminal.clientMessageID, code: "TEST_REJECTED")
            let pool = await store.databasePool
            try await pool.write { try $0.execute(sql: "UPDATE v2_pending_message_commands SET terminal_at = 200 WHERE client_message_id = ?", arguments: [terminal.clientMessageID.rawValue]) }
            let before = try await store.pendingMessageCommands()
            await #expect(throws: V2ClientCommandError.commandConflict) {
                if stage == "expire" { try await store.expireStalePendingCommands(now: Date(timeIntervalSince1970: seconds)) }
                else { try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: seconds)) }
            }
            #expect(try await store.pendingMessageCommands() == before)
            try await store.expireStalePendingCommands(now: Date(timeIntervalSince1970: 1_000 + V2IdempotencyPolicy.maximumClientRetryAge))
            let expired = try await store.pendingMessageCommands()
            #expect(expired.first { $0.clientMessageID == old.clientMessageID }?.state == .rejected)
            #expect(expired.first { $0.clientMessageID == recent.clientMessageID }?.state == .pending)
            try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 199))
            #expect(try await store.pendingMessageCommands().count == 3)
            try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 200))
            #expect(try await store.pendingMessageCommands().map(\.clientMessageID) == [old.clientMessageID, recent.clientMessageID])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("stale pending commands become visible terminal failures before replay")
    func expiresPendingCommandsAtTheProtocolWindow() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryTerminalRetentionDatabaseURL(),
            installationBinding: terminalRetentionInstallationBinding
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000981")
        let old = try pendingMessage(
            roomID: roomID,
            clientMessageID: "00000000-0000-0000-0000-000000000982",
            createdAt: 100
        )
        let recent = try pendingMessage(
            roomID: roomID,
            clientMessageID: "00000000-0000-0000-0000-000000000983",
            createdAt: 1_100
        )
        try await store.enqueue(old)
        try await store.enqueue(recent)

        let expirationTime = Date(
            timeIntervalSince1970: 1_000 + V2IdempotencyPolicy.maximumClientRetryAge
        )
        try await store.expireStalePendingCommands(now: expirationTime)
        try await store.pruneTerminalCommands(
            olderThan: expirationTime.addingTimeInterval(-86_400)
        )

        let remaining: [V2PendingMessageCommand] = try await store.pendingMessageCommands()
        #expect(remaining.map(\.state) == [.rejected, .pending])
        #expect(remaining.map(\.terminalCode) == [
            V2IdempotencyPolicy.expiredClientCommandCode,
            nil
        ])
        #expect(try await store.nextReadyMessage(now: .distantFuture)?.clientMessageID == recent.clientMessageID)
    }

    @Test("terminal commands expire while pending commands remain durable")
    func pruningExpiresOnlyOldTerminalCommands() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryTerminalRetentionDatabaseURL(),
            installationBinding: terminalRetentionInstallationBinding
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000991")
        let oldAccepted = try V2PendingMessageCommand(
            roomID: roomID,
            clientMessageID: .init("00000000-0000-0000-0000-000000000992"),
            text: "old accepted",
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 100),
            acceptedMessageID: nil,
            acceptedRoomSequence: nil,
            terminalCode: nil
        )
        let recentRejected = try V2PendingMessageCommand(
            roomID: roomID,
            clientMessageID: .init("00000000-0000-0000-0000-000000000993"),
            text: "recent rejected",
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 1_001),
            acceptedMessageID: nil,
            acceptedRoomSequence: nil,
            terminalCode: nil
        )
        let oldPending = try V2PendingMessageCommand(
            roomID: roomID,
            clientMessageID: .init("00000000-0000-0000-0000-000000000994"),
            text: "old pending",
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 100),
            acceptedMessageID: nil,
            acceptedRoomSequence: nil,
            terminalCode: nil
        )

        try await store.enqueue(oldAccepted)
        try await store.enqueue(recentRejected)
        try await store.enqueue(oldPending)
        try await store.markMessageAccepted(
            clientMessageID: oldAccepted.clientMessageID,
            messageID: try MessageID("00000000-0000-0000-0000-000000000995"),
            roomSequence: 1
        )
        try await store.rejectMessage(
            clientMessageID: recentRejected.clientMessageID,
            code: "POLICY_DENIED"
        )
        let databasePool = await store.databasePool
        try await databasePool.write { db in
            try db.execute(
                sql: "UPDATE v2_pending_message_commands SET terminal_at = ? WHERE client_message_id = ?",
                arguments: [100, oldAccepted.clientMessageID.rawValue]
            )
            try db.execute(
                sql: "UPDATE v2_pending_message_commands SET terminal_at = ? WHERE client_message_id = ?",
                arguments: [1_001, recentRejected.clientMessageID.rawValue]
            )
        }

        try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 1_000))

        let remaining: [V2PendingMessageCommand] = try await store.pendingMessageCommands()
        #expect(remaining.map { $0.clientMessageID } == [oldPending.clientMessageID, recentRejected.clientMessageID])
        #expect(remaining.map { $0.state } == [V2PendingMessageCommand.State.pending, .rejected])
    }

    @Test("retention preserves replay-active group creation states")
    func pruningPreservesGroupCreationStateMachine() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryTerminalRetentionDatabaseURL(),
            installationBinding: terminalRetentionInstallationBinding
        )
        let cancellingID = try GroupRoomOperationID("00000000-0000-0000-0000-000000000970")
        let finalizingID = try GroupRoomOperationID("00000000-0000-0000-0000-000000000971")

        for (operationID, title) in [(cancellingID, "cancelling"), (finalizingID, "finalizing")] {
            try await store.enqueue(try V2PendingGroupRoomCreation(
                operationID: operationID,
                title: title,
                capacityClass: .standard,
                initialMemberUserIDs: [],
                state: .pending,
                attemptCount: 0,
                nextAttemptAt: Date(timeIntervalSince1970: 100),
                createdRoomID: nil,
                terminalCode: nil
            ))
            try await store.beginCancellingGroupRoomCreation(
                operationID: operationID,
                now: Date(timeIntervalSince1970: 200)
            )
        }
        try await store.resumeGroupRoomCreationAfterCancellationRefusal(
            operationID: finalizingID,
            now: Date(timeIntervalSince1970: 300)
        )

        try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 1_000))

        var creations = try await store.pendingGroupRoomCreations()
        #expect(creations.map(\.operationID) == [cancellingID, finalizingID])
        #expect(creations.map(\.state) == [.cancelling, .finalizing])

        try await store.expireStalePendingCommands(
            now: Date(timeIntervalSince1970: 100 + V2IdempotencyPolicy.maximumClientRetryAge)
        )
        creations = try await store.pendingGroupRoomCreations()
        #expect(creations.map(\.state) == [.rejected, .rejected])
        #expect(creations.map(\.terminalCode) == [
            V2IdempotencyPolicy.expiredClientCommandCode,
            V2IdempotencyPolicy.expiredClientCommandCode
        ])
    }

    @Test("terminal bulk-forward plans and their chunks are pruned together")
    func pruningRemovesTerminalForwardPlanGraph() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: temporaryTerminalRetentionDatabaseURL(),
            installationBinding: terminalRetentionInstallationBinding
        )
        let operationID = try MessageForwardOperationID("00000000-0000-0000-0000-000000000972")
        let sourceID = try MessageID("00000000-0000-0000-0000-000000000973")
        let roomID = try RoomID("00000000-0000-0000-0000-000000000974")
        let plan = V2ForwardMessagesPlan(
            operationID: operationID,
            sourceMessageCount: 1,
            targetRoomCount: 1,
            totalForwardCount: 1,
            succeededCount: 0,
            failedCount: 0,
            state: .active, terminalCode: nil
        )
        _ = try await store.enqueueForwardPlan(
            plan,
            sources: [try testForwardReference(sourceID)],
            targetRoomIDs: [roomID],
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(try await store.nextReadyForwardPlanChunk(now: Date(timeIntervalSince1970: 100)) != nil)
        try await store.cancelForwardPlan(
            operationID: operationID,
            now: Date(timeIntervalSince1970: 200)
        )

        try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 199))
        #expect(try await store.forwardPlan(operationID: operationID) != nil)

        try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 200))
        #expect(try await store.forwardPlan(operationID: operationID) == nil)
    }

    private func pendingMessage(
        roomID: RoomID,
        clientMessageID: String,
        createdAt: TimeInterval
    ) throws -> V2PendingMessageCommand {
        try .init(
            roomID: roomID,
            clientMessageID: .init(clientMessageID),
            text: "pending",
            state: .pending,
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: createdAt),
            acceptedMessageID: nil,
            acceptedRoomSequence: nil,
            terminalCode: nil
        )
    }
}

private func temporaryTerminalRetentionDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "im-v2-terminal-retention-\(UUID().uuidString).sqlite")
}

private let terminalRetentionInstallationBinding = V2LocalInstallationBinding(
    value: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!
)
