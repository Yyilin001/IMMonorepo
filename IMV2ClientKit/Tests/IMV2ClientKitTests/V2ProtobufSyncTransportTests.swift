import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing

struct V2ProtobufSyncTransportTests {
    @Test("bounded background confirmation preserves progress arriving during its snapshot")
    func backgroundConfirmationSnapshot() async throws {
        let wire = DeviceProgressWorkerWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let room = RoomID(uuid: UUID())
        try await transport.enqueueDeviceRoomProgress(roomID: room, appliedThrough: 3)
        let flush = Task { try await transport.flushDeviceRoomProgressReports() }
        var batches = wire.batches.makeAsyncIterator()
        #expect(await batches.next() == [room: 3])
        try await transport.enqueueDeviceRoomProgress(roomID: room, appliedThrough: 5)
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.flushDeviceRoomProgressReports()
        }
        await wire.release()
        try await flush.value
        try await transport.flushDeviceRoomProgressReports()
        #expect(await batches.next() == [room: 5])
    }
    @Test("a revoked room does not stall other device confirmations")
    func revokedRoomDoesNotBlockConfirmations() async throws {
        let revoked = RoomID(uuid: UUID()), allowed = RoomID(uuid: UUID())
        let wire = ForbiddenDeviceProgressWire(revoked: revoked)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        try await transport.enqueueDeviceRoomProgress(roomID: revoked, appliedThrough: 3)
        try await transport.enqueueDeviceRoomProgress(roomID: allowed, appliedThrough: 5)
        let worker = Task { try await transport.runDeviceRoomProgressReports() }
        var accepted = wire.accepted.makeAsyncIterator()
        #expect(await accepted.next() == allowed)
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
    }
    @Test("confirmation worker coalesces rooms and keeps progress arriving during an acknowledgement")
    func confirmationWorkerCoalescing() async throws {
        let wire = DeviceProgressWorkerWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
        try await transport.enqueueDeviceRoomProgress(roomID: a, appliedThrough: 3)
        try await transport.enqueueDeviceRoomProgress(roomID: a, appliedThrough: 5)
        let worker = Task { try await transport.runDeviceRoomProgressReports() }
        var batches = wire.batches.makeAsyncIterator()
        let first = try #require(await batches.next())
        #expect(first == [a: 5])
        try await transport.enqueueDeviceRoomProgress(roomID: a, appliedThrough: 8)
        try await transport.enqueueDeviceRoomProgress(roomID: b, appliedThrough: 2)
        await wire.release()
        let second = try #require(await batches.next())
        #expect(second == [a: 8, b: 2])
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
    }
    @Test("device progress uses an independent room batch and validates the exact acknowledgement", arguments: [false, true])
    func deviceProgressAcknowledgement(wrongAcknowledgement: Bool) async throws {
        let wire = DeviceProgressWire(wrongAcknowledgement: wrongAcknowledgement)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let cursors: [RoomID: UInt64] = [RoomID(uuid: UUID()): 3, RoomID(uuid: UUID()): 8]
        if wrongAcknowledgement {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
                try await transport.reportDeviceRoomProgress(cursors)
            }
        } else {
            try await transport.reportDeviceRoomProgress(cursors)
        }
        #expect(await wire.roomCount == 2)
    }
    @Test("Sync BUSY cannot extend its deadline or retry on a replacement connection", arguments: [false, true])
    func syncBusyRejectsFloorOrNewGeneration(replaced: Bool) async throws {
        let wire = BusyScopeWire(replaced: replaced)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        if replaced {
            await #expect(throws: V2TLSFrameConnectionError.connectionClosed) {
                _ = try await transport.pull(syncToken: nil, maxRecords: 100)
            }
        } else {
            await #expect(throws: V2RealtimeTransportError.server(code: "SERVER_BUSY", retryable: true,
                retryAfterSeconds: 11, currentRevision: nil)) {
                _ = try await transport.pull(syncToken: nil, maxRecords: 100)
            }
        }
        #expect(await wire.requests == 1)
    }

    @Test("snapshot expiry checks reject invalid local clocks and preserve the exact expiry boundary", arguments: ["nan", "negativeInfinity", "positiveInfinity", "belowMinimum", "aboveMaximum", "negative", "epoch", "beforeExpiry", "atExpiry", "afterExpiry"])
    func snapshotExpiryClockBounds(scenario: String) async throws {
        let expiry = Date.distantFuture
        let clock: Date
        switch scenario {
        case "nan": clock = Date(timeIntervalSince1970: .nan)
        case "negativeInfinity": clock = Date(timeIntervalSince1970: -.infinity)
        case "positiveInfinity": clock = Date(timeIntervalSince1970: .infinity)
        case "belowMinimum": clock = Date(timeIntervalSince1970: Double(Int64.min) / 1000 - 10)
        case "aboveMaximum": clock = Date(timeIntervalSince1970: Double(Int64.max) / 1000 + 10)
        case "negative": clock = Date(timeIntervalSince1970: -1)
        case "epoch": clock = Date(timeIntervalSince1970: 0)
        case "beforeExpiry": clock = expiry.addingTimeInterval(-1)
        case "atExpiry": clock = expiry
        default: clock = expiry.addingTimeInterval(1)
        }
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 7, expiresAt: expiry)
        let wire = ScriptedSyncWire(reset: reset)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1, now: { clock })
        if ["negative", "epoch", "beforeExpiry"].contains(scenario) {
            #expect(try await transport.fetchSnapshotManifest(for: reset).reset == reset)
        } else {
            await #expect(throws: V2RealtimeTransportError.invalidSnapshotManifest) {
                try await transport.fetchSnapshotManifest(for: reset)
            }
        }
        #expect(await wire.commands() == [.syncSnapshot])
    }

    @Test("room event wire validates scanned boundaries and forward progress", arguments: ["empty", "payload", "emptyMore", "badBound", "stalled", "regressed"])
    func scannedRoomCursorWire(_ scenario: String) async throws {
        let room = RoomID(uuid: UUID())
        let transport = V2ProtobufSyncTransport(wire: ScannedRoomCursorWire(scenario: scenario), protocolVersion: UInt8(IMV2ProtocolVersion.current))
        if ["badBound", "stalled", "regressed"].contains(scenario) {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
                try await transport.pullGroupEvents(roomID: room, afterRoomSequence: 2, pageSize: 2)
            }
        } else {
            let page = try await transport.pullGroupEvents(roomID: room, afterRoomSequence: 2, pageSize: 2)
            #expect(page.nextRoomSequence == 5)
            #expect(page.events.count == (scenario == "payload" ? 1 : 0))
            #expect(page.hasMore == (scenario == "emptyMore"))
        }
    }


    @Test("explicit rebuild intent is encoded on the authenticated sync pull")
    func rebuildIntentUsesWire() async throws {
        let wire = SnapshotRebuildWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        _ = try await transport.pull(syncToken: nil, maxRecords: 20, requireSnapshot: true)
        #expect(await wire.observedRebuild())
    }

    @Test("snapshot wire rejects counts beyond the codec page limit", arguments: [UInt32(0), 1, 500, 501, UInt32.max])
    func snapshotWireItemCountBounds(value: UInt32) async throws {
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 7, expiresAt: .distantFuture)
        let wire = ScriptedSyncWire(reset: reset, responseItemCount: value)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let manifest = try await transport.fetchSnapshotManifest(for: reset)
        if value == 0 || value > V2SnapshotProjectionV3Codec.maximumPageItems {
            await #expect(throws: V2RealtimeTransportError.snapshotDigestMismatch) {
                try await transport.fetchSnapshotPage(for: manifest, index: 0)
            }
        } else {
            #expect(try await transport.fetchSnapshotPage(for: manifest, index: 0).itemCount == Int(value))
        }
        #expect(await wire.commands() == [.syncSnapshot, .snapshotPagePull])
    }

    @Test("snapshot manifest pages are correlated and SHA-256 verified before acknowledgement")
    func snapshotRoundTrip() async throws {
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000301"),
            generation: 2,
            baseSequence: 7,
            expiresAt: .distantFuture
        )
        let wire = ScriptedSyncWire(reset: reset)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)

        let manifest = try await transport.fetchSnapshotManifest(for: reset)
        #expect(manifest.pageCount == 1)
        #expect(manifest.totalItems == 1)
        #expect(manifest.capabilityProfile == "base")
        let page = try await transport.fetchSnapshotPage(for: manifest, index: 0)
        #expect(page.itemCount == 1)
        #expect(try V2SnapshotProjectionV3Codec.decode(page.payload).items.count == 1)
        try await transport.acknowledgeSnapshot(manifest)
        #expect(await wire.commands() == [.syncSnapshot, .snapshotPagePull, .snapshotAck])
    }

    @Test("a response correlated to another request ID is never accepted")
    func rejectsMismatchedCorrelation() async throws {
        let transport = V2ProtobufSyncTransport(wire: WrongCorrelationWire(), protocolVersion: 1)
        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.acknowledge(generation: 1, highestContiguousSequence: 1, receipt: try .init("receipt"))
        }
    }

    @Test("TLS endpoint rejects empty host and zero port before attempting a network connection")
    func rejectsInvalidEndpoint() {
        #expect(throws: V2TLSFrameConnectionError.invalidEndpoint) { _ = try V2RealtimeEndpoint(host: "", port: 7443) }
        #expect(throws: V2TLSFrameConnectionError.invalidEndpoint) { _ = try V2RealtimeEndpoint(host: "gateway.example", port: 0) }
    }

    @Test("heartbeat uses the same correlated authenticated transport")
    func heartbeatRoundTrips() async throws {
        let wire = HeartbeatWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)

        try await transport.sendHeartbeat(clientTime: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(await wire.receivedHeartbeat())
    }

    @Test("heartbeat reports durable C and discovers a lost final body and hint through authoritative H")
    func heartbeatRoomProgress() async throws {
        let wire = RoomProgressHeartbeatWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1,
            durableRoomProgress: { _ in 4 })
        try await transport.sendHeartbeat()
        #expect(await wire.reportedApplied == 4)
        #expect(await wire.receivedHead == 7)
    }

    @Test("heartbeat without durable cursor still discovers authoritative room head")
    func heartbeatRoomStateWithoutProgress() async throws {
        let wire = RoomProgressHeartbeatWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1,
            durableRoomProgress: { _ in nil })
        try await transport.sendHeartbeat()
        #expect(await wire.reportedApplied == nil)
        #expect(await wire.receivedHead == 7)
    }

    @Test("a recovering server room state does not become Ready or wake room pulling")
    func heartbeatRecoveringRoomState() async throws {
        let wire = RoomProgressHeartbeatWire(ready: false)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1,
            durableRoomProgress: { _ in 4 })
        try await transport.sendHeartbeat()
        #expect(await wire.reportedApplied == 4)
        #expect(await wire.receivedHead == nil)
        #expect(await wire.roomProgressScope()?.scopeGeneration == 2)
    }

    @Test("snapshot manifests with a different projection schema are rejected before a reset begins")
    func rejectsUnsupportedSnapshotSchema() async throws {
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000317"),
            generation: 2,
            baseSequence: 7,
            expiresAt: .distantFuture
        )
        let transport = V2ProtobufSyncTransport(wire: ScriptedSyncWire(reset: reset, schemaVersion: 1), protocolVersion: 1)
        await #expect(throws: V2RealtimeTransportError.invalidSnapshotManifest) {
            _ = try await transport.fetchSnapshotManifest(for: reset)
        }
    }

    @Test("frozen withdrawal preserves original identity across Codable transport")
    func messageWithdrawalRoundTrips() throws {
        let command = try V2MessageWithdrawalOperationCommand(command: .init(roomID: .init(uuid: UUID()), actorUserID: .init(uuid: UUID()),
            operationID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), expectedMessageRevision: 1), firstSubmissionDeadlineMilliseconds: 1000)
        let restored = try JSONDecoder().decode(V2MessageWithdrawalOperationCommand.self, from: JSONEncoder().encode(command))
        #expect(restored == command)
        #expect(try restored.identity == command.identity)
        #expect(try restored.fingerprint == command.fingerprint)
    }

    @Test("retired mutation wire fields no longer decode as executable requests", arguments: [22,43,44,45,47,49,51,52,53,55,58,67,68,69,70,71,72,73,74,76,80,97,99,101,103])
    func retiredMutationWire(field: Int) throws {
        let tag=(field<<3)|2
        let envelope = try IMV2Envelope(serializedBytes: [UInt8(tag & 127)|128, UInt8(tag>>7), UInt8(0)])
        #expect(envelope.body == nil)
    }

    @Test("member directory uses a bounded page and maps canonical roles")
    func membershipDirectoryRoundTrips() async throws {
        let wire = MembershipDirectoryWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000340")

        let page = try await transport.listRoomMembers(roomID: roomID, cursor: nil, pageSize: 100)

        #expect(page.roomID == roomID)
        #expect(page.membershipRevision == 6)
        #expect(page.actorRole == .owner)
        #expect(page.members.map(\.role) == [.owner, .member])
        #expect(page.members.map(\.userID.rawValue) == ["00000000-0000-0000-0000-000000000341", "00000000-0000-0000-0000-000000000342"])
        #expect(page.nextCursor == "00000000-0000-0000-0000-000000000342")
        #expect(await wire.requestedPageSize() == 100)
    }







    @Test("member directory rejects an unknown role even when the user ID is valid")
    func membershipDirectoryRejectsUnknownRole() async throws {
        let transport = V2ProtobufSyncTransport(
            wire: MembershipDirectoryWire(validRole: false),
            protocolVersion: 1
        )

        await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
            try await transport.listRoomMembers(
                roomID: .init("00000000-0000-0000-0000-000000000340"),
                cursor: nil,
                pageSize: 100
            )
        }
    }

    @Test("read-receipt details bind pagination to the exact message")
    func readReceiptReaderPaginationRoundTrips() async throws {
        let wire = ReadReceiptReadersWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000343")
        let messageID = try MessageID("00000000-0000-0000-0000-000000000346")

        let first = try await transport.listReadReceiptReaders(
            roomID: roomID, messageID: messageID, cursor: nil, pageSize: 1
        )
        guard let cursor = first.nextCursor else {
            Issue.record("expected a first-page cursor")
            return
        }
        let second = try await transport.listReadReceiptReaders(
            roomID: roomID, messageID: messageID,
            cursor: cursor, pageSize: 1
        )

        #expect(first.messageID == messageID)
        #expect(first.readers.count == 1)
        #expect(first.readers[0].userID.rawValue == "00000000-0000-0000-0000-000000000344")
        #expect(second.readers.count == 1)
        #expect(second.nextCursor == nil)
    }

    @Test("Hybrid group subscription maps its cursor and best-effort unsubscribe")
    func groupEventSubscriptionRoundTrips() async throws {
        let wire = GroupEventSubscriptionWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000350")

        let subscription = try await transport.subscribeToGroupEvents(roomID: roomID, afterRoomSequence: 21)
        try await transport.unsubscribeFromGroupEvents(roomID: roomID)

        #expect(subscription == (try .init(roomID: roomID, highWatermark: 34)))
        #expect(await wire.commands() == [.groupEventSubscribe, .groupEventUnsubscribe])
        #expect(await wire.afterRoomSequence() == 21)
    }
}

@Suite("Receipt directory wire bounds")
struct V2ReceiptDirectoryBoundsTests {
    @Test("reader pages reject invalid routing, duplicate identities and unbounded/non-advancing cursors",
          arguments: ["wrong-room", "wrong-message", "oversized", "duplicate", "long-cursor", "same-cursor", "invalid-id"])
    func invalidPages(_ scenario: String) async throws {
        let wire = InvalidReceiptPageWire(scenario: scenario)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        await #expect(throws: (any Error).self) {
            _ = try await transport.listReadReceiptReaders(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()),
                cursor: "cursor", pageSize: 2)
        }
    }

    @Test("oversized input is rejected before transport admission")
    func oversizedInput() async throws {
        let wire = InvalidReceiptPageWire(scenario: "unexpected")
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        for cursor in ["", String(repeating: "a", count: 513)] {
            await #expect(throws: V2RealtimeTransportError.unexpectedResponse) {
                _ = try await transport.listReadReceiptReaders(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()),
                    cursor: cursor, pageSize: 2)
            }
        }
        #expect(await wire.calls == 0)
    }
}

private actor InvalidReceiptPageWire: V2AuthenticatedFrameTransport {
    let scenario: String
    private(set) var calls = 0
    init(scenario: String) { self.scenario = scenario }
    func request(_ frame: V2Frame) throws -> V2Frame {
        calls += 1
        let request = try V2ProtobufFrameCodec.decode(frame)
        let command = request.listReadReceiptReaders
        var response = IMV2Envelope()
        response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        var page = IMV2ReadReceiptReadersPage()
        page.roomID = scenario == "wrong-room" ? UUID().uuidString : command.roomID
        page.messageID = scenario == "wrong-message" ? UUID().uuidString : command.messageID
        let reader = IMV2ReadReceiptReader.with { $0.userID = scenario == "invalid-id" ? "" : UUID().uuidString }
        page.readers = [reader]
        if scenario == "oversized" { page.readers += (0..<2).map { _ in .with { $0.userID = UUID().uuidString } } }
        if scenario == "duplicate" { page.readers.append(reader) }
        if scenario == "long-cursor" { page.nextCursor = String(repeating: "a", count: 513) }
        if scenario == "same-cursor" { page.nextCursor = command.cursor }
        response.readReceiptReadersPage = page
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}

private actor GroupEventSubscriptionWire: V2AuthenticatedFrameTransport {
    private var receivedCommands: [V2FrameCommand] = []
    private var receivedAfterRoomSequence: UInt64 = 0

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        receivedCommands.append(frame.command)
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        switch request.body {
        case .groupEventSubscribe(let subscribe):
            receivedAfterRoomSequence = subscribe.afterRoomSequence
            response.groupEventSubscribed = .init()
            response.groupEventSubscribed.roomID = subscribe.roomID
            response.groupEventSubscribed.highWatermark = 34
        case .groupEventUnsubscribe:
            response.acknowledged = .init()
        default:
            throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func commands() -> [V2FrameCommand] { receivedCommands }
    func afterRoomSequence() -> UInt64 { receivedAfterRoomSequence }
}

/// 会话摘要线替身：按构造时给定的未读数回答一页摘要。
///
/// 默认给出 3 条未读与 12 的房间头，因此"未读不超过房间头"成立；测试可以通过构造
/// 参数制造越界响应，验证客户端不会接受自相矛盾的计数。


private actor MembershipDirectoryWire: V2AuthenticatedFrameTransport {
    private var pageSize: UInt32 = 0
    private let validRole: Bool

    init(validRole: Bool = true) {
        self.validRole = validRole
    }

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .listRoomMembers(let command)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        pageSize = command.pageSize
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.roomMembersPage = .init()
        response.roomMembersPage.roomID = command.roomID
        response.roomMembersPage.membershipRevision = 6
        response.roomMembersPage.actorRole = .owner
        response.roomMembersPage.members = [
            .with {
                $0.userID = "00000000-0000-0000-0000-000000000341"
                $0.role = validRole ? .owner : .UNRECOGNIZED(99)
            },
            .with {
                $0.userID = "00000000-0000-0000-0000-000000000342"
                $0.role = .member
            }
        ]
        response.roomMembersPage.nextCursor = "00000000-0000-0000-0000-000000000342"
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func requestedPageSize() -> UInt32 { pageSize }
}

private actor ReadReceiptReadersWire: V2AuthenticatedFrameTransport {
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .listReadReceiptReaders(let command)? = request.body else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let isFirstPage = command.cursor.isEmpty
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.readReceiptReadersPage = .init()
        response.readReceiptReadersPage.roomID = command.roomID
        response.readReceiptReadersPage.messageID = command.messageID
        response.readReceiptReadersPage.readers = [.with {
            $0.userID = isFirstPage
                ? "00000000-0000-0000-0000-000000000344"
                : "00000000-0000-0000-0000-000000000345"
        }]
        response.readReceiptReadersPage.nextCursor = isFirstPage ? "opaque-cursor" : ""
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}



private actor ForbiddenDeviceProgressWire: V2AuthenticatedFrameTransport {
    let revoked: RoomID
    nonisolated let accepted: AsyncStream<RoomID>
    private let continuation: AsyncStream<RoomID>.Continuation
    init(revoked: RoomID) {
        self.revoked = revoked
        let stream = AsyncStream<RoomID>.makeStream()
        accepted = stream.stream; continuation = stream.continuation
    }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .deviceRoomProgressReport(let report)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        var response = IMV2Envelope()
        response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        if report.rooms.contains(where: { $0.roomID == revoked.rawValue }) {
            response.error = .init(); response.error.code = "FORBIDDEN"; response.error.retryable = false
        } else {
            response.deviceRoomProgressRecorded = .init(); response.deviceRoomProgressRecorded.rooms = report.rooms
            for room in report.rooms { continuation.yield(try RoomID(room.roomID)) }
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}

private actor DeviceProgressWorkerWire: V2AuthenticatedFrameTransport {
    nonisolated let batches: AsyncStream<[RoomID: UInt64]>
    private let continuation: AsyncStream<[RoomID: UInt64]>.Continuation
    private var first = true
    private var gate: CheckedContinuation<Void, Never>?
    init() {
        let stream = AsyncStream<[RoomID: UInt64]>.makeStream()
        batches = stream.stream; continuation = stream.continuation
    }
    func release() { gate?.resume(); gate = nil }
    func request(_ frame: V2Frame) async throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .deviceRoomProgressReport(let report)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        let values = try Dictionary(uniqueKeysWithValues: report.rooms.map { (try RoomID($0.roomID), $0.appliedThrough) })
        continuation.yield(values)
        if first {
            first = false
            await withCheckedContinuation { gate = $0 }
        }
        var response = IMV2Envelope()
        response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        response.deviceRoomProgressRecorded = .init()
        response.deviceRoomProgressRecorded.rooms = report.rooms
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}

private actor DeviceProgressWire: V2AuthenticatedFrameTransport {
    let wrongAcknowledgement: Bool
    private(set) var roomCount = 0
    init(wrongAcknowledgement: Bool) { self.wrongAcknowledgement = wrongAcknowledgement }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .deviceRoomProgressReport(let report)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        roomCount = report.rooms.count
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.deviceRoomProgressRecorded = .init()
        response.deviceRoomProgressRecorded.rooms = wrongAcknowledgement ? [] : report.rooms
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}

private actor HeartbeatWire: V2AuthenticatedFrameTransport {
    private var didReceiveHeartbeat = false

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .heartbeat = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        didReceiveHeartbeat = true
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = 1
        response.heartbeatAck = .init()
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func receivedHeartbeat() -> Bool { didReceiveHeartbeat }
}

private actor ScriptedSyncWire: V2AuthenticatedFrameTransport {
    private let reset: V2ClientResetRequired
    private let schemaVersion: UInt32
    private var recorded: [V2FrameCommand] = []
    private let pagePayload: Data
    private let responseItemCount: UInt32
    private let pageDigest: String
    private let rootDigest: String
    private let firstKey: V2SnapshotProjectionKey
    private let lastKey: V2SnapshotProjectionKey

    init(reset: V2ClientResetRequired, schemaVersion: UInt32 = V2SnapshotProjectionV3Codec.schemaVersion, responseItemCount: UInt32 = 1) {
        self.responseItemCount = responseItemCount
        self.reset = reset
        self.schemaVersion = schemaVersion
        let key = try! V2SnapshotProjectionKey(
            projectionKind: "relationship",
            entityKey: "00000000-0000-0000-0000-000000000302"
        )
        let item = try! V2SnapshotProjectionItem(
            key: key,
            sourceEventID: .init("00000000-0000-0000-0000-000000000303"),
            sequence: 1,
            payload: JSONSerialization.data(withJSONObject: [
                "target_user_id": key.entityKey,
                "state": "accepted",
                "updated_at_ms": 1_750_000_000_000,
            ], options: [.sortedKeys])
        )
        let page = try! V2SnapshotProjectionV3Page(items: [item])
        pagePayload = try! V2SnapshotProjectionV3Codec.encode(page)
        pageDigest = V2SnapshotV3Digest.page(pagePayload)
        firstKey = page.firstKey
        lastKey = page.lastKey
        rootDigest = V2SnapshotV3Digest.next(
            previous: V2SnapshotV3Digest.initial(baseSequence: reset.baseSequence, capabilityProfile: "base"),
            pageIndex: 0,
            pageDigest: pageDigest,
            firstKey: page.firstKey,
            lastKey: page.lastKey,
            itemCount: 1
        )
    }

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        recorded.append(frame.command)
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        switch request.body {
        case .syncSnapshot:
            response.snapshotManifest = .init()
            response.snapshotManifest.snapshotID = reset.snapshotID.rawValue
            response.snapshotManifest.generation = reset.generation
            response.snapshotManifest.baseUserSyncSequence = reset.baseSequence
            response.snapshotManifest.rootDigest = rootDigest
            response.snapshotManifest.schemaVersion = schemaVersion
            response.snapshotManifest.capabilityProfile = "base"
            response.snapshotManifest.pageCount = 1
            response.snapshotManifest.totalItems = 1
            response.snapshotManifest.totalBytes = UInt64(pagePayload.count)
            response.snapshotManifest.nextSyncToken = "next-token"
            response.snapshotManifest.syncReceipt = "snapshot-receipt"
            response.snapshotManifest.expiresAtMs = Int64(Date.distantFuture.timeIntervalSince1970 * 1_000)
        case .snapshotPagePull:
            response.snapshotPage = .init()
            response.snapshotPage.snapshotID = reset.snapshotID.rawValue
            response.snapshotPage.generation = reset.generation
            response.snapshotPage.rootDigest = rootDigest
            response.snapshotPage.pageIndex = 0
            response.snapshotPage.pageDigest = pageDigest
            response.snapshotPage.firstProjectionKind = firstKey.projectionKind
            response.snapshotPage.firstEntityKey = firstKey.entityKey
            response.snapshotPage.lastProjectionKind = lastKey.projectionKind
            response.snapshotPage.lastEntityKey = lastKey.entityKey
            response.snapshotPage.itemCount = responseItemCount
            response.snapshotPage.payload = pagePayload
        case .snapshotAck:
            response.acknowledged = .init()
        default:
            response.error = .init()
            response.error.code = "UNEXPECTED"
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func commands() -> [V2FrameCommand] { recorded }
}

private struct WrongCorrelationWire: V2AuthenticatedFrameTransport {
    func request(_ frame: V2Frame) throws -> V2Frame {
        var response = IMV2Envelope()
        response.requestID = frame.requestID + 1
        response.protocolVersion = 1
        response.acknowledged = .init()
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}

private actor SnapshotRebuildWire: V2AuthenticatedFrameTransport {
    private var rebuild = false
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .syncPull(let pull)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        rebuild = pull.requireSnapshot && pull.syncToken.isEmpty
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.resetRequired = .init()
        response.resetRequired.snapshotID = "00000000-0000-0000-0000-000000009006"
        response.resetRequired.generation = 2
        response.resetRequired.baseUserSyncSequence = 10
        response.resetRequired.expiresAtMs = 2_000_000_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
    func observedRebuild() -> Bool { rebuild }
}

private struct ScannedRoomCursorWire: V2AuthenticatedFrameTransport {
    let scenario: String
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .groupEventPull(let pull)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        var response = IMV2Envelope()
        response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        response.groupEventPage = .init()
        response.groupEventPage.roomID = pull.roomID
        response.groupEventPage.nextRoomSequence = scenario == "regressed" ? 1 : (scenario == "stalled" ? 2 : 5)
        response.groupEventPage.hasMore_p = scenario == "emptyMore" || scenario == "stalled"
        if scenario == "payload" || scenario == "badBound" {
            var event = IMV2GroupEvent()
            event.sourceEventID = UUID().uuidString
            event.roomSequence = scenario == "badBound" ? 6 : 3
            event.projectionKind = "message"; event.payload = Data("{}".utf8)
            response.groupEventPage.events = [event]
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: UInt8(request.protocolVersion))
    }
}

private actor BusyScopeWire: V2AuthenticatedFrameTransport {
    let replaced: Bool
    var generation = UUID()
    var requests = 0
    init(replaced: Bool) { self.replaced = replaced }
    func authenticatedConnectionID() -> UUID? { generation }
    func request(_ frame: V2Frame) throws -> V2Frame {
        #expect(V2ConnectionRequestScope.connectionID == generation)
        requests += 1
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope(); response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        response.error.code = "SERVER_BUSY"; response.error.retryable = true
        response.error.retryAfterSeconds = replaced ? 0 : 11
        if replaced { generation = UUID() }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: frame.version)
    }
}

actor RoomProgressHeartbeatWire: V2AuthenticatedFrameTransport, V2RoomProgressConnection {
    let connectionID = UUID()
    let room: RoomID
    let ready: Bool
    let serverAccepted: UInt64?
    var reportedApplied: UInt64?
    var receivedHead: UInt64?

    init(room: RoomID = RoomID(uuid: UUID()), ready: Bool = true, serverAccepted: UInt64? = nil) {
        self.room = room; self.ready = ready; self.serverAccepted = serverAccepted
    }

    func authenticatedConnectionID() -> UUID? { connectionID }
    func roomProgressScope() -> V2RealtimeCoverageState? {
        var coverage = IMV2RealtimeCoverage()
        coverage.scope = .room
        coverage.scopeID = room.rawValue
        coverage.scopeGeneration = 2
        coverage.highWatermark = 4
        coverage.revision = 1
        coverage.state = .ready
        coverage.reason = .unspecified
        return try? V2RealtimeCoverageState(wire: coverage, generation: connectionID)
    }
    func acceptRoomProgressHead(roomID: String, scopeGeneration: UInt64, highWatermark: UInt64,
                                connectionID incomingConnection: UUID) throws {
        #expect(roomID == room.rawValue)
        #expect(scopeGeneration == 2)
        #expect(incomingConnection == connectionID)
        receivedHead = highWatermark
    }
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .heartbeat(let heartbeat)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        #expect(heartbeat.roomProgress.count <= 1)
        if let progress = heartbeat.roomProgress.first {
            #expect(progress.roomID == room.rawValue)
            #expect(progress.scopeGeneration == 2)
            reportedApplied = progress.appliedRoomSequence
        }
        var state = IMV2GroupEventProgressState()
        state.roomID = room.rawValue
        state.scopeGeneration = 2
        state.highWatermark = 7
        state.appliedRoomSequence = serverAccepted ?? reportedApplied ?? 0
        state.ready = ready
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = 1
        response.heartbeatAck = .init()
        response.heartbeatAck.roomSubscriptionStates = [state]
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }
}
