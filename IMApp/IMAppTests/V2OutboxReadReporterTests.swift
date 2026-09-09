import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxReadReporterTests {
    @Test("a cancelled read report does not enqueue a receipt")
    func cancelledReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-receipt-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let room = RoomID(uuid: UUID())
            let reporter = V2OutboxConversationReadReporter(outbox: .init(store: store, transport: ReceiptTransport(rejectedRoom: nil)))
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await reporter.recordReadThrough(roomID: room.rawValue, roomSequence: 1)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.pendingReadReceipts().isEmpty)
            #expect(try await reporter.recordReadThrough(roomID: room.rawValue, roomSequence: 1) == .recorded)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("another room's receipt does not determine the current report", arguments: [false, true])
    func receiptCorrelation(rejectOld: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-receipt-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let oldRoom = RoomID(uuid: UUID())
            let room = RoomID(uuid: UUID())
            let transport = ReceiptTransport(rejectedRoom: rejectOld ? oldRoom : nil)
            let olderOutbox = V2ReadReceiptOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 999) })
            let older = try await olderOutbox.enqueueReceipt(roomID: oldRoom, readThroughRoomSequence: 1)
            let outbox = V2ReadReceiptOutboxEngine(store: store, transport: transport, now: { Date(timeIntervalSince1970: 1_000) })
            let reporter = V2OutboxConversationReadReporter(outbox: outbox)
            #expect(try await reporter.recordReadThrough(roomID: room.rawValue, roomSequence: 2) == .queuedForRetry)
            let commands = try await store.pendingReadReceipts()
            let current = try #require(commands.first { $0.roomID == room })
            #expect(current.state == .pending)
            #expect(commands.first { $0.operationID == older.operationID }?.state == (rejectOld ? .rejected : .acknowledged))
            #expect(try await outbox.flushOnce() == .acknowledged(current.operationID))
            #expect(try await reporter.recordReadThrough(roomID: room.rawValue, roomSequence: 2) == .alreadyRecorded)
            #expect(try await reporter.recordReadThrough(roomID: room.rawValue, roomSequence: 3) == .recorded)
            #expect(try await store.pendingReadReceipts().count == 3)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct ReceiptTransport: V2ClientReadReceiptTransport {
    let rejectedRoom: RoomID?
    func setReadReceiptPreferences(operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferences {
        Issue.record("receipt reporting must not update preferences")
        throw V2RealtimeTransportError.unexpectedResponse
    }
    func listReadReceiptReaders(roomID: RoomID, messageID: MessageID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        Issue.record("receipt reporting must not list readers")
        throw V2RealtimeTransportError.unexpectedResponse
    }
    func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) async throws -> V2ClientReadReceipt {
        if roomID == rejectedRoom {
            throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
        }
        return try .init(roomID: roomID, userID: .init(uuid: UUID()), readThroughRoomSequence: readThroughRoomSequence, recordedAt: Date(timeIntervalSince1970: 1_000))
    }
}
