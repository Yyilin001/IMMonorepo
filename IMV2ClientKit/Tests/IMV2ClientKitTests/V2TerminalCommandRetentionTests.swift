import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 terminal command retention")
struct V2TerminalCommandRetentionTests {
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

        try await store.pruneTerminalCommands(olderThan: Date(timeIntervalSince1970: 1_000))

        let remaining: [V2PendingMessageCommand] = try await store.pendingMessageCommands()
        #expect(remaining.map { $0.clientMessageID } == [oldPending.clientMessageID, recentRejected.clientMessageID])
        #expect(remaining.map { $0.state } == [V2PendingMessageCommand.State.pending, .rejected])
    }
}

private func temporaryTerminalRetentionDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "im-v2-terminal-retention-\(UUID().uuidString).sqlite")
}

private let terminalRetentionInstallationBinding = V2LocalInstallationBinding(
    value: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!
)
