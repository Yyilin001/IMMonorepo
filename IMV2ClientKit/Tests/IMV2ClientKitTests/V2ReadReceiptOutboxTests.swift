import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

@Suite("V2 read receipt outbox")
struct V2ReadReceiptOutboxTests {
    @Test("restart retries the exact viewing operation without touching sync state")
    func retrySurvivesRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-receipt-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ReceiptTransport(results: [.offline, .accepted])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: receiptBinding)
        let first = V2ReadReceiptOutboxEngine(store: store, transport: transport, makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000981")! }, now: { now })
        let command = try await first.enqueueReceipt(roomID: .init("00000000-0000-0000-0000-000000000982"), readThroughRoomSequence: 8)
        #expect(try await first.flushOnce() == .retryScheduled(command.operationID))

        let restarted = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: receiptBinding)
        let second = V2ReadReceiptOutboxEngine(store: restarted, transport: transport, now: { now.addingTimeInterval(1) })
        #expect(try await second.flushOnce() == .acknowledged(command.operationID))
        let saved = try #require(await restarted.pendingReadReceipts().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.state == .acknowledged)
        #expect(saved.resultingRoomSequence == 8)
        #expect(await transport.operationIDs() == [command.operationID, command.operationID])
    }

    @Test("an older receipt response cannot advance the durable viewing state")
    func rejectsStaleReceiptResponse() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-receipt-stale-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let transport = ReceiptTransport(results: [.stale])
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: receiptBinding)
        let engine = V2ReadReceiptOutboxEngine(
            store: store,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000985")! },
            now: { now }
        )
        let command = try await engine.enqueueReceipt(roomID: .init("00000000-0000-0000-0000-000000000982"), readThroughRoomSequence: 8)

        #expect(try await engine.flushOnce() == .retryScheduled(command.operationID))
        let saved = try #require(await store.pendingReadReceipts().first)
        #expect(saved.operationID == command.operationID)
        #expect(saved.state == .pending)
        #expect(saved.attemptCount == 1)
        #expect(saved.resultingRoomSequence == nil)
    }

    @Test("unpersistable uint64 receipt sequences are rejected before SQLite conversion")
    func rejectsSequenceBeyondSignedStorageRange() async throws {
        let store = try GRDBV2LocalSyncStore(
            databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-v2-receipt-range-\(UUID().uuidString).sqlite"),
            installationBinding: receiptBinding
        )
        let engine = V2ReadReceiptOutboxEngine(store: store, transport: ReceiptTransport(results: []))

        await #expect(throws: V2ClientCommandError.commandConflict) {
            _ = try await engine.enqueueReceipt(
                roomID: .init("00000000-0000-0000-0000-000000000982"),
                readThroughRoomSequence: UInt64(Int64.max) + 1
            )
        }
        #expect((try await store.pendingReadReceipts()).isEmpty)
    }

    @Test("persisted pending and acknowledged receipts suppress duplicate viewing operations")
    func suppressesDuplicateOrOlderReceiptsAcrossRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "im-v2-receipt-dedupe-\(UUID().uuidString).sqlite")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000982")
        let firstStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: receiptBinding)
        let first = V2ReadReceiptOutboxEngine(store: firstStore, transport: ReceiptTransport(results: [.accepted]), makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000986")! }, now: { now })

        let firstCommand = try #require(await first.enqueueReceiptIfAdvancing(roomID: roomID, readThroughRoomSequence: 8))
        #expect(try await first.enqueueReceiptIfAdvancing(roomID: roomID, readThroughRoomSequence: 8) == nil)
        #expect(try await first.enqueueReceiptIfAdvancing(roomID: roomID, readThroughRoomSequence: 7) == nil)
        #expect(try await first.flushOnce() == .acknowledged(firstCommand.operationID))

        let restartedStore = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: receiptBinding)
        let restarted = V2ReadReceiptOutboxEngine(store: restartedStore, transport: ReceiptTransport(results: []), now: { now.addingTimeInterval(1) })
        #expect(try await restarted.enqueueReceiptIfAdvancing(roomID: roomID, readThroughRoomSequence: 8) == nil)
        #expect(try await restarted.enqueueReceiptIfAdvancing(roomID: roomID, readThroughRoomSequence: 9) != nil)
    }
}

private actor ReceiptTransport: V2ClientReadReceiptTransport {
    enum Result: Sendable { case offline, stale, accepted }
    private var results: [Result]; private var received: [ReadReceiptOperationID] = []
    init(results: [Result]) { self.results = results }
    func recordReadReceipt(roomID: RoomID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) throws -> V2ClientReadReceipt {
        received.append(operationID)
        switch results.removeFirst() {
        case .offline: throw V2RealtimeTransportError.unexpectedResponse
        case .stale: return try .init(roomID: roomID, userID: try! .init("00000000-0000-0000-0000-000000000983"), readThroughRoomSequence: readThroughRoomSequence - 1, recordedAt: .distantPast)
        case .accepted: return try .init(roomID: roomID, userID: try! .init("00000000-0000-0000-0000-000000000983"), readThroughRoomSequence: readThroughRoomSequence, recordedAt: .distantPast)
        }
    }
    func setReadReceiptPreferences(operationID _: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts _: Bool, allowsGroupReadReceipts _: Bool) throws -> V2ReadReceiptPreferences {
        throw V2RealtimeTransportError.unexpectedResponse
    }
    func listReadReceiptReaders(roomID _: RoomID, messageID _: MessageID, cursor _: String?, pageSize _: Int) throws -> V2ReadReceiptReadersPage {
        throw V2RealtimeTransportError.unexpectedResponse
    }
    func operationIDs() -> [ReadReceiptOperationID] { received }
}

private let receiptBinding = V2LocalInstallationBinding(value: UUID(uuidString: "00000000-0000-0000-0000-000000000984")!)
