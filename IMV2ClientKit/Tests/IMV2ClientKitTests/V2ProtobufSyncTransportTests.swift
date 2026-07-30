import Foundation
import IMV2ClientKit
import IMV2Core
import Testing

struct V2ProtobufSyncTransportTests {
    @Test("snapshot manifest pages are correlated and SHA-256 verified before acknowledgement")
    func snapshotRoundTrip() async throws {
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000301"),
            generation: 2,
            baseSequence: 7,
            manifestDigest: "manifest-digest",
            expiresAt: .distantFuture
        )
        let wire = ScriptedSyncWire(reset: reset)
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)

        let manifest = try await transport.fetchSnapshotManifest(for: reset)
        #expect(manifest.pageDigests.count == 1)
        #expect(manifest.capabilityProfile == "base")
        let page = try await transport.fetchSnapshotPage(for: manifest, index: 0)
        #expect(page.payload == Data("hello".utf8))
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

    @Test("membership operations preserve their stable operation ID on the authenticated wire")
    func membershipChangeRoundTrips() async throws {
        let wire = MembershipWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let result = try await transport.changeMembership(
            roomID: .init("00000000-0000-0000-0000-000000000311"),
            operationID: .init("00000000-0000-0000-0000-000000000312"),
            targetUserID: .init("00000000-0000-0000-0000-000000000313"),
            action: .add,
            expectedMembershipRevision: 4
        )
        #expect(result.membershipRevision == 5)
        #expect(await wire.operationID() == "00000000-0000-0000-0000-000000000312")
    }

    @Test("direct room and stranger-message preference preserve their operation IDs")
    func directMessagingRoundTrips() async throws {
        let wire = DirectMessagingWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let target = try UserID("00000000-0000-0000-0000-000000000318")
        let room = try await transport.openDirectRoom(operationID: try .init("00000000-0000-0000-0000-000000000319"), targetUserID: target)
        let updatedAt = try await transport.setStrangerMessagePermission(operationID: try .init("00000000-0000-0000-0000-000000000320"), permission: .deny)
        #expect(room.targetUserID == target)
        #expect(updatedAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(await wire.operationIDs() == ["00000000-0000-0000-0000-000000000319", "00000000-0000-0000-0000-000000000320"])
    }

    @Test("staged group creation preserves durable intent and bounded response")
    func groupCreationRoundTrips() async throws {
        let wire = GroupMessagingWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let member = try UserID("00000000-0000-0000-0000-000000000327")
        let operationID: GroupRoomOperationID = try .init("00000000-0000-0000-0000-000000000326")
        let prepared = try await transport.beginGroupRoomCreation(operationID: operationID, title: "  Project  ")
        let appended = try await transport.appendGroupRoomCreationMembers(operationID: operationID, memberUserIDs: [member])
        let room = try await transport.finalizeGroupRoomCreation(operationID: operationID)
        #expect(prepared.title == "Project")
        #expect(appended.stagedMemberCount == 1)
        #expect(room.title == "Project")
        #expect(room.memberUserIDs.isEmpty)
        #expect(await wire.operationID() == "00000000-0000-0000-0000-000000000326")
    }

    @Test("relationship and block commands preserve operation IDs and canonical state")
    func socialRelationshipRoundTrips() async throws {
        let wire = SocialRelationshipWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let target = try UserID("00000000-0000-0000-0000-000000000323")
        let relationship = try await transport.changeRelationship(operationID: try .init("00000000-0000-0000-0000-000000000324"), targetUserID: target, action: .request)
        let block = try await transport.changeUserBlock(operationID: try .init("00000000-0000-0000-0000-000000000325"), targetUserID: target, action: .block)
        #expect(relationship.targetUserID == target)
        #expect(relationship.resultingState == .pending)
        #expect(block.isBlocked)
        #expect(await wire.operationIDs() == ["00000000-0000-0000-0000-000000000324", "00000000-0000-0000-0000-000000000325"])
    }

    @Test("membership revision conflict preserves the authoritative revision")
    func membershipRevisionConflictCarriesCurrentRevision() async throws {
        let transport = V2ProtobufSyncTransport(wire: MembershipRevisionConflictWire(), protocolVersion: 1)
        await #expect(throws: V2RealtimeTransportError.server(code: "REVISION_CONFLICT", retryable: false, retryAfterSeconds: 0, currentRevision: 12)) {
            try await transport.changeMembership(
                roomID: .init("00000000-0000-0000-0000-000000000314"),
                operationID: .init("00000000-0000-0000-0000-000000000315"),
                targetUserID: .init("00000000-0000-0000-0000-000000000316"),
                action: .remove,
                expectedMembershipRevision: 11
            )
        }
    }

    @Test("snapshot manifests with a different projection schema are rejected before a reset begins")
    func rejectsUnsupportedSnapshotSchema() async throws {
        let reset = try V2ClientResetRequired(
            snapshotID: .init("00000000-0000-0000-0000-000000000317"),
            generation: 2,
            baseSequence: 7,
            manifestDigest: "manifest-digest",
            expiresAt: .distantFuture
        )
        let transport = V2ProtobufSyncTransport(wire: ScriptedSyncWire(reset: reset, schemaVersion: 1), protocolVersion: 1)
        await #expect(throws: V2RealtimeTransportError.invalidSnapshotManifest) {
            _ = try await transport.fetchSnapshotManifest(for: reset)
        }
    }

    @Test("message withdrawal preserves its operation ID and validates the authoritative revision")
    func messageWithdrawalRoundTrips() async throws {
        let wire = MessageWithdrawalWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let result = try await transport.withdrawMessage(
            roomID: .init("00000000-0000-0000-0000-000000000321"),
            operationID: .init("00000000-0000-0000-0000-000000000322"),
            messageID: .init("00000000-0000-0000-0000-000000000323"),
            expectedMessageRevision: 1
        )
        #expect(result.messageRevision == 2)
        #expect(await wire.operationID() == "00000000-0000-0000-0000-000000000322")
    }

    @Test("message redaction preserves its moderator operation ID and reason code")
    func messageRedactionRoundTrips() async throws {
        let wire = MessageRedactionWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let result = try await transport.redactMessage(
            roomID: .init("00000000-0000-0000-0000-000000000326"),
            operationID: .init("00000000-0000-0000-0000-000000000327"),
            messageID: .init("00000000-0000-0000-0000-000000000328"),
            reasonCode: .init("policy_violation")
        )
        #expect(result.messageRevision == 2)
        #expect(await wire.command() == ("00000000-0000-0000-0000-000000000327", "policy_violation"))
    }

    @Test("member mute preserves its operation and bounded expiry on the authenticated wire")
    func memberMuteRoundTrips() async throws {
        let wire = MemberMuteWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let muteUntil = Date(timeIntervalSince1970: 1_750_000_300)
        let result = try await transport.muteMember(roomID: .init("00000000-0000-0000-0000-000000000329"), operationID: .init("00000000-0000-0000-0000-000000000330"), targetUserID: .init("00000000-0000-0000-0000-000000000331"), muteUntil: muteUntil, reasonCode: .init("abuse_spam"))
        #expect(result.muteUntil == muteUntil)
        #expect(await wire.operationID() == "00000000-0000-0000-0000-000000000330")
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
        #expect(page.members.first?.publicIdentity?.handle.rawValue == "owner_1")
        #expect(page.members.first?.publicIdentity?.displayName == "群主")
        #expect(page.members.last?.publicIdentity?.handle.rawValue == "member_2")
        #expect(page.nextCursor == "00000000-0000-0000-0000-000000000342")
        #expect(await wire.requestedPageSize() == 100)
    }

    @Test("Hybrid group subscription maps its cursor and best-effort unsubscribe")
    func groupEventSubscriptionRoundTrips() async throws {
        let wire = GroupEventSubscriptionWire()
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: 1)
        let roomID = try RoomID("00000000-0000-0000-0000-000000000350")

        let subscription = try await transport.subscribeToGroupEvents(roomID: roomID, afterRoomSequence: 21)
        try await transport.unsubscribeFromGroupEvents(roomID: roomID)

        #expect(subscription == .init(roomID: roomID, highWatermark: 34))
        #expect(await wire.commands() == [.groupEventSubscribe, .groupEventUnsubscribe])
        #expect(await wire.afterRoomSequence() == 21)
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

private actor MembershipDirectoryWire: V2AuthenticatedFrameTransport {
    private var pageSize: UInt32 = 0

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
                $0.role = .owner
                $0.publicHandle = "owner_1"
                $0.displayName = "群主"
            },
            .with {
                $0.userID = "00000000-0000-0000-0000-000000000342"
                $0.role = .member
                $0.publicHandle = "member_2"
                $0.displayName = "成员二"
            }
        ]
        response.roomMembersPage.nextCursor = "00000000-0000-0000-0000-000000000342"
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func requestedPageSize() -> UInt32 { pageSize }
}

private actor MemberMuteWire: V2AuthenticatedFrameTransport {
    private var receivedOperationID = ""

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .muteMember(let command)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        receivedOperationID = command.operationID
        var response = IMV2Envelope(); response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        response.memberMuted = .init()
        response.memberMuted.roomID = command.roomID
        response.memberMuted.targetUserID = command.targetUserID
        response.memberMuted.muteUntilMs = command.muteUntilMs
        response.memberMuted.roomSequence = 9
        response.memberMuted.serverCreatedAtMs = 1_750_000_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func operationID() -> String { receivedOperationID }
}

private actor MessageRedactionWire: V2AuthenticatedFrameTransport {
    private var received: (String, String) = ("", "")

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .moderateMessage(let command)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        received = (command.operationID, command.reasonCode)
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.messageRedacted = .init()
        response.messageRedacted.roomID = command.roomID
        response.messageRedacted.messageID = command.messageID
        response.messageRedacted.messageRevision = 2
        response.messageRedacted.roomSequence = 8
        response.messageRedacted.serverCreatedAtMs = 1_750_000_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func command() -> (String, String) { received }
}

private actor MessageWithdrawalWire: V2AuthenticatedFrameTransport {
    private var receivedOperationID = ""

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .withdrawMessage(let command)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        receivedOperationID = command.operationID
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.messageWithdrawn = .init()
        response.messageWithdrawn.roomID = command.roomID
        response.messageWithdrawn.messageID = command.messageID
        response.messageWithdrawn.messageRevision = command.expectedMessageRevision + 1
        response.messageWithdrawn.roomSequence = 8
        response.messageWithdrawn.serverCreatedAtMs = 1_750_000_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func operationID() -> String { receivedOperationID }
}

private actor MembershipWire: V2AuthenticatedFrameTransport {
    private var receivedOperationID = ""

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        guard case .changeRoomMembership(let command)? = request.body else { throw V2RealtimeTransportError.unexpectedResponse }
        receivedOperationID = command.operationID
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.membershipChanged = .init()
        response.membershipChanged.roomID = command.roomID
        response.membershipChanged.targetUserID = command.targetUserID
        response.membershipChanged.action = command.action
        response.membershipChanged.membershipRevision = 5
        response.membershipChanged.roomSequence = 8
        response.membershipChanged.serverCreatedAtMs = 1_750_000_000_000
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func operationID() -> String { receivedOperationID }
}

private actor DirectMessagingWire: V2AuthenticatedFrameTransport {
    private var receivedOperationIDs: [String] = []

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        switch request.body {
        case .openDirectRoom(let command):
            receivedOperationIDs.append(command.operationID)
            response.directRoomOpened = .init()
            response.directRoomOpened.roomID = "00000000-0000-0000-0000-000000000321"
            response.directRoomOpened.targetUserID = command.targetUserID
            response.directRoomOpened.createdAtMs = 1_750_000_000_000
        case .setStrangerMessagePermission(let command):
            receivedOperationIDs.append(command.operationID)
            response.strangerMessagePermissionSet = .init()
            response.strangerMessagePermissionSet.permission = command.permission
            response.strangerMessagePermissionSet.updatedAtMs = 1_750_000_000_000
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func operationIDs() -> [String] { receivedOperationIDs }
}

private actor GroupMessagingWire: V2AuthenticatedFrameTransport {
    private var receivedOperationID = ""
    private var title = ""
    private var stagedMembers: [String] = []

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope(); response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        switch request.body {
        case .beginGroupRoomCreation(let command):
            receivedOperationID = command.operationID; title = command.title.trimmingCharacters(in: .whitespacesAndNewlines)
            response.groupRoomCreationPrepared = .init()
            response.groupRoomCreationPrepared.operationID = command.operationID
            response.groupRoomCreationPrepared.title = title
        case .appendGroupRoomCreationMembers(let command):
            receivedOperationID = command.operationID; stagedMembers.append(contentsOf: command.memberUserIds)
            response.groupRoomCreationMembersAppended = .init()
            response.groupRoomCreationMembersAppended.operationID = command.operationID
            response.groupRoomCreationMembersAppended.stagedMemberCount = UInt32(stagedMembers.count)
        case .finalizeGroupRoomCreation(let command):
            receivedOperationID = command.operationID
            response.groupRoomCreated = .init()
            response.groupRoomCreated.roomID = "00000000-0000-0000-0000-000000000328"
            response.groupRoomCreated.title = title
            response.groupRoomCreated.createdAtMs = 1_750_000_000_000
            response.groupRoomCreated.deliveryMode = .standardFanout
            response.groupRoomCreated.memberCount = UInt32(stagedMembers.count + 1)
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func operationID() -> String { receivedOperationID }
}

private actor SocialRelationshipWire: V2AuthenticatedFrameTransport {
    private var receivedOperationIDs: [String] = []

    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope(); response.requestID = request.requestID; response.protocolVersion = request.protocolVersion
        switch request.body {
        case .changeRelationship(let command):
            receivedOperationIDs.append(command.operationID)
            response.relationshipChanged = .init()
            response.relationshipChanged.targetUserID = command.targetUserID
            response.relationshipChanged.action = command.action
            response.relationshipChanged.resultingState = .pending
            response.relationshipChanged.updatedAtMs = 1_750_000_000_000
        case .changeUserBlock(let command):
            receivedOperationIDs.append(command.operationID)
            response.userBlockChanged = .init()
            response.userBlockChanged.targetUserID = command.targetUserID
            response.userBlockChanged.action = command.action
            response.userBlockChanged.isBlocked = command.action == .block
            response.userBlockChanged.updatedAtMs = 1_750_000_000_000
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
    }

    func operationIDs() -> [String] { receivedOperationIDs }
}

private struct MembershipRevisionConflictWire: V2AuthenticatedFrameTransport {
    func request(_ frame: V2Frame) throws -> V2Frame {
        let request = try V2ProtobufFrameCodec.decode(frame)
        var response = IMV2Envelope()
        response.requestID = request.requestID
        response.protocolVersion = request.protocolVersion
        response.error = .init()
        response.error.code = "REVISION_CONFLICT"
        response.error.currentRevision = 12
        return try V2ProtobufFrameCodec.encode(response, frameVersion: 1)
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

    init(reset: V2ClientResetRequired, schemaVersion: UInt32 = V2SnapshotProjectionCodec.schemaVersion) {
        self.reset = reset
        self.schemaVersion = schemaVersion
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
            response.snapshotManifest.manifestDigest = reset.manifestDigest
            response.snapshotManifest.schemaVersion = schemaVersion
            response.snapshotManifest.capabilityProfile = "base"
            response.snapshotManifest.pageDigests = ["2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"]
            response.snapshotManifest.nextSyncToken = "next-token"
            response.snapshotManifest.syncReceipt = "snapshot-receipt"
            response.snapshotManifest.expiresAtMs = Int64(Date.distantFuture.timeIntervalSince1970 * 1_000)
        case .snapshotPagePull:
            response.snapshotPage = .init()
            response.snapshotPage.snapshotID = reset.snapshotID.rawValue
            response.snapshotPage.generation = reset.generation
            response.snapshotPage.manifestDigest = reset.manifestDigest
            response.snapshotPage.pageIndex = 0
            response.snapshotPage.pageDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            response.snapshotPage.payload = Data("hello".utf8)
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
