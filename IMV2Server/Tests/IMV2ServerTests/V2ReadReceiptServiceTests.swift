@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 read receipt service")
struct V2ReadReceiptServiceTests {
    @Test("Receipt sequence bounds are checked before direct storage or batch admission",
          arguments: [false, true], [UInt64(0), 1, UInt64(Int64.max), UInt64(Int64.max) + 1, UInt64.max])
    func validatesSequenceBeforeAdmission(batched: Bool, sequence: UInt64) async throws {
        let store = ReceiptStoreSpy()
        let admission = ReceiptAdmissionSpy()
        let service = V2ReadReceiptService(store: store, batcher: batched ? admission : nil,
            now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let request = V2AuthenticatedReadReceipt(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
            operationID: .init(uuid: UUID()), readThroughRoomSequence: sequence)
        if sequence == 0 || sequence > UInt64(Int64.max) {
            await #expect(throws: V2ReadReceiptValidationError.invalidRoomSequence) { try await service.record(request) }
            #expect(await store.command() == nil)
            #expect(await admission.command() == nil)
        } else {
            guard case .recorded(let receipt) = try await service.record(request) else { throw CancellationError() }
            #expect(receipt.readThroughRoomSequence == sequence)
            if batched {
                #expect(await admission.command()?.readThroughRoomSequence == sequence)
                #expect(await store.command() == nil)
            } else {
                #expect(await store.command()?.readThroughRoomSequence == sequence)
                #expect(await admission.command() == nil)
            }
        }
    }

    @Test("explicit viewing state reaches the store independently of sync acknowledgements")
    func forwardsReadReceipt() async throws {
        let store = ReceiptStoreSpy()
        let service = V2ReadReceiptService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let request = V2AuthenticatedReadReceipt(roomID: try .init("00000000-0000-0000-0000-000000000971"), actorUserID: try .init("00000000-0000-0000-0000-000000000972"), operationID: try .init("00000000-0000-0000-0000-000000000973"), readThroughRoomSequence: 8)
        let expected = try V2RecordReadReceiptCommand(roomID: request.roomID, actorUserID: request.actorUserID, operationID: request.operationID, readThroughRoomSequence: 8)
        let result = try await service.record(request)
        guard case .recorded(let receipt) = result else { Issue.record("expected receipt"); return }
        #expect(await store.command() == expected)
        #expect(receipt.readThroughRoomSequence == 8)
    }
}

private actor ReceiptStoreSpy: V2ReadReceiptStore {
    private var captured: V2RecordReadReceiptCommand?
    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        captured = command
        return .recorded(try .init(roomID: command.roomID, userID: command.actorUserID, readThroughRoomSequence: command.readThroughRoomSequence, recordedAt: now))
    }
    func setPreferences(command _: V2SetReadReceiptPreferencesCommand, now _: Date) throws -> V2SetReadReceiptPreferencesOutcome {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }
    func readers(roomID _: RoomID, messageID _: MessageID, actorUserID _: UserID, cursor _: String?, pageSize _: Int) throws -> V2ReadReceiptReadersPage {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }
    func command() -> V2RecordReadReceiptCommand? { captured }
}

private actor ReceiptAdmissionSpy: V2ReadReceiptAdmission {
    nonisolated var managesForegroundWriteAdmission: Bool { true }
    private var captured: V2RecordReadReceiptCommand?
    func accept(_ request: V2ReadReceiptRecordRequest) throws -> V2ReadReceiptOutcome {
        captured = request.command
        return .recorded(try .init(roomID: request.command.roomID, userID: request.command.actorUserID,
            readThroughRoomSequence: request.command.readThroughRoomSequence, recordedAt: request.now))
    }
    func command() -> V2RecordReadReceiptCommand? { captured }
}
