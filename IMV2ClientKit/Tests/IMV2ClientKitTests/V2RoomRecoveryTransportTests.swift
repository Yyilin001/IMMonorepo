import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Room recovery wire contract")
struct V2RoomRecoveryTransportTests {
    @Test("account listener start returns a validated epoch", arguments: [false, true])
    func accountStart(invalid: Bool) async throws {
        let epoch = UUID()
        let transport: any V2ClientRoomRecoveryTransport = makeTransport { request in
            guard case .accountRoomChangesStart? = request.body else {
                Issue.record("Expected account listener start")
                return .init()
            }
            var response = IMV2Envelope()
            response.accountRoomChangesReady.connectionEpoch = invalid ? "invalid" : epoch.uuidString
            return response
        }
        if invalid {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { try await transport.startAccountRoomChanges() }
        } else {
            #expect(try await transport.startAccountRoomChanges() == epoch)
        }
    }

    @Test("topology invalidation requests a fresh scan instead of retrying an expired cursor")
    func directoryReset() async throws {
        let transport = makeTransport { _ in
            var response = IMV2Envelope()
            response.error.code = "ROOM_DIRECTORY_RESET_REQUIRED"
            response.error.retryable = true
            return response
        }
        await #expect(throws: V2ClientRoomRecoveryError.directoryResetRequired) {
            try await transport.userRoomDirectory(cursor: "expired", pageSize: 10)
        }
    }

    @Test("filtered empty directory pages retain their continuation")
    func emptyPage() async throws {
        let transport = makeTransport { request in
            #expect(request.userRoomDirectoryList.cursor == "previous")
            var response = IMV2Envelope()
            response.userRoomDirectoryPage.topologyGeneration = "generation"
            response.userRoomDirectoryPage.nextCursor = "next"
            return response
        }
        let page = try await transport.userRoomDirectory(cursor: "previous", pageSize: 10)
        #expect(page.rooms.isEmpty && page.nextCursor == "next")
    }

    @Test("an unchanged continuation cannot create an infinite directory loop")
    func stalledCursor() async throws {
        let transport = makeTransport { _ in
            var response = IMV2Envelope()
            response.userRoomDirectoryPage.topologyGeneration = "generation"
            response.userRoomDirectoryPage.nextCursor = "previous"
            return response
        }
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.userRoomDirectory(cursor: "previous", pageSize: 10)
        }
    }

    @Test("a missing, duplicated or uncorrelated result cannot imply catch-up", arguments: [0, 1, 2])
    func invalidBatch(mode: Int) async throws {
        let room = RoomID(uuid: UUID())
        let transport = makeTransport { _ in
            var response = IMV2Envelope()
            var item = IMV2RoomSyncStateResult()
            item.roomID = mode == 2 ? UUID().uuidString : room.rawValue
            item.unavailable = .init()
            response.roomSyncStateBatchResult.rooms = mode == 0 ? [] : mode == 1 ? [item, item] : [item]
            return response
        }
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.roomSyncStates(roomIDs: [room])
        }
    }

    @Test("unread is validated against the same head and personal counters", arguments: [false, true])
    func unreadValidation(corrupt: Bool) async throws {
        let room = RoomID(uuid: UUID())
        let transport = makeTransport { request in
            #expect(request.roomSyncStateBatch.roomIds == [room.rawValue])
            var response = IMV2Envelope()
            var item = IMV2RoomSyncStateResult()
            item.roomID = room.rawValue
            item.state.roomID = room.rawValue
            item.state.viewerMembershipRevision = 1
            item.state.head = 10
            item.state.readThrough = 8
            item.state.latestOwnMessageSequence = 9
            item.state.unreadCount = corrupt ? 2 : 1
            response.roomSyncStateBatchResult.rooms = [item]
            return response
        }
        if corrupt {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
                try await transport.roomSyncStates(roomIDs: [room])
            }
        } else {
            let expected = try V2RoomSynchronizationState(roomID: room, ownerEpoch: 0, viewerMembershipRevision: 1,
                head: 10, trimmedThrough: 0, readThrough: 8, latestOwnMessageSequence: 9)
            #expect(try await transport.roomSyncStates(roomIDs: [room, room])[room] == .state(expected))
        }
    }

    @Test(arguments: [false, true])
    func latestVisibleRoundTripAndMissingResult(missing: Bool) async throws {
        let room = RoomID(uuid: UUID())
        let transport = makeTransport { request in
            #expect(request.roomLatestVisibleBatch.roomIds == [room.rawValue])
            var response = IMV2Envelope()
            var item = IMV2RoomLatestVisibleResult()
            item.roomID = room.rawValue
            item.snapshot.ownerEpoch = 1
            item.snapshot.viewerMembershipRevision = 2
            item.snapshot.head = 7
            response.roomLatestVisibleBatchResult.rooms = missing ? [] : [item]
            return response
        }
        if missing {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) { try await transport.latestVisible(roomIDs: [room]) }
        } else {
            let values = try await transport.latestVisible(roomIDs: [room])
            let expected = try V2RoomLatestVisible(roomID: room, ownerEpoch: 1, membershipRevision: 2, head: 7, latest: nil)
            #expect(values[room] == .snapshot(expected))
        }
    }

    private func makeTransport(_ respond: @escaping @Sendable (IMV2Envelope) -> IMV2Envelope) -> V2ProtobufSyncTransport {
        .init(wire: RecoveryFrameWire(respond: respond), protocolVersion: UInt8(IMV2ProtocolVersion.current))
    }
}

private struct RecoveryFrameWire: V2AuthenticatedFrameTransport {
    let respond: @Sendable (IMV2Envelope) -> IMV2Envelope
    func request(_ frame: V2Frame) async throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = respond(request)
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}
