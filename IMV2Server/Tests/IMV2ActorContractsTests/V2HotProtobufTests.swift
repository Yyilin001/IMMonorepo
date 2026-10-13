import Foundation
import IMV2Core
import SwiftProtobuf
import Testing
@testable import IMV2ActorContracts

@Suite("Fixed hot Protobuf contracts")
struct V2HotProtobufTests {
    private let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
    private func token() throws -> V2RoomActivationToken {
        try .init(roomID: room, owner: .init(shardID: "rooms", epoch: 0), activationEpoch: .init(1), host: .init(hostID: .init("owner"), incarnationID: UUID()))
    }
    private func fence() throws -> V2RoomSubscriptionFence { try .init(activation: token(), subscriptionID: UUID(), generation: UInt64.max, baselineSequence: 0) }
    private func descriptor() -> V2GatewayRealtimeDescriptor {
        .init(identity: .init(nodeID: "gw", serviceID: "gateway", incarnationID: UUID()), endpointReference: Data(0..<255), address: "127.0.0.1", port: 9999)
    }
    private func send() throws -> V2MessageSendOperationCommand {
        try .init(command: .init(roomID: room, senderUserID: user, clientMessageID: .init(uuid: UUID()), text: "中文 😀 https://example.com",
            media: [.init(mediaID: .init(uuid: UUID()))], mentions: [.user(.init(uuid: UUID())), .everyone],
            entities: [.init(offsetUTF16: 0, lengthUTF16: 2, kind: .bold), .init(offsetUTF16: 6, lengthUTF16: 19, kind: .link, linkURL: URL(string: "https://example.com"))],
            replyTo: .init(messageID: .init(uuid: UUID())), limits: .init(maxUTF8Bytes: 1_048_576)),
            firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000)
    }
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> Bool {
        try V2ActorProtobuf.decode(T.self, from: V2ActorProtobuf.encode(value)) == value
    }
    @Test func borrowedSubrangeDecodesHotAndGenericModels() throws {
        let request = V2RoomRequest.messaging(.sendOperation(try send()))
        var packet = Data(repeating: 255, count: 16)
        packet.append(try V2ActorProtobuf.encode(request)); packet.append(255)
        let body = packet.bytes.extracting(16..<(packet.count - 1))
        #expect(try V2ActorProtobuf.decode(V2RoomRequest.self, from: body) == request)
        let generic = try V2ActorProtobuf.encodeValue(["中文😀", ""])
        #expect(try V2ActorProtobuf.decode([String].self, from: generic.bytes) == ["中文😀", ""])
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: packet.bytes) }
    }
    @Test func richSendUsesFixedFieldsAndPreservesFingerprints() throws {
        let command = try send(), request = V2RoomRequest.messaging(.sendOperation(command))
        let bytes = try V2ActorProtobuf.encode(request), wire = try Im_Actor_V1_HotRoomRequest(serializedBytes: bytes)
        guard case .send(let body) = wire.operation else { Issue.record("send went through generic body"); return }
        #expect(body.text == command.command.text && body.mediaIds.count == 1 && body.entities.count == 2 && body.hasReplyMessageID)
        let decoded = try V2ActorProtobuf.decode(V2RoomRequest.self, from: bytes)
        #expect(decoded == request)
        guard case .messaging(.sendOperation(let value)) = decoded else { return }
        let actualIdentity = try value.identity, expectedIdentity = try command.identity
        let actualFingerprint = try value.fingerprint, expectedFingerprint = try command.fingerprint
        #expect(actualIdentity == expectedIdentity)
        #expect(actualFingerprint == expectedFingerprint)
        let genericSize = try V2ActorProtobuf.encodeValue(request).count
        #expect(bytes.count < genericSize)
    }
    @Test func sendResultsKeepIdentityAndOptionalRetry() throws {
        let command = try send(), identity = try command.identity, fingerprint = try command.fingerprint
        let receipt = try V2MessageSendOperationReceipt(identity: identity, fingerprint: fingerprint,
            outcome: .accepted(.init(messageID: .init(uuid: UUID()), roomSequence: UInt64(Int64.max))), resolvedAtMilliseconds: 1)
        let rejected = try V2MessageSendOperationReceipt(identity: identity, fingerprint: fingerprint, outcome: .rejected(.directPolicyDenied), resolvedAtMilliseconds: 2)
        var values: [V2MessageSendOperationRecoveryResult] = [.receipt(receipt), .receipt(rejected), .unresolved, .fingerprintConflict]
        for after: UInt64? in [nil, 1, 86_400_000] {
            values.append(.deferred(try .init(identity: identity, fingerprint: fingerprint, reason: .admissionUnavailable, retryAfterMilliseconds: after)))
        }
        for value in values { #expect(try roundTrip(V2RoomResponse.messaging(.sendOperation(value)))) }
    }
    @Test func subscriptionCommandsAndResults() throws {
        let fence = try fence(), gateway = descriptor()
        let commands: [V2RoomSubscriptionCommand] = [
            .subscribe(.init(roomID: room, actorUserID: user, gatewayDescriptor: gateway)),
            .activate(.init(roomID: room, actorUserID: user, gatewayDescriptor: gateway, fence: fence)),
            .reset(.init(roomID: room, actorUserID: user, gatewayDescriptor: gateway, expectedFence: fence)),
            .unsubscribe(.init(roomID: room, actorUserID: user, gatewayDescriptor: gateway, memberRevision: 9))]
        for command in commands { #expect(try roundTrip(V2RoomRequest.roomSubscription(command))) }
        let results: [V2RoomSubscriptionResult] = [.activated, .unsubscribed, .failure(.stale),
            .granted(.init(fence: fence, memberRevision: 4, userBaselineSequence: 5, deliverySession: .init(host: fence.activation.host, gateway: gateway.identity, generation: 1)))]
        for result in results { #expect(try roundTrip(V2RoomResponse.roomSubscription(result))) }
    }
    private func event() -> V2RealtimeRoomEvent {
        .init(roomID: room, highWatermark: 9, sourceEventID: .init(uuid: UUID()), roomSequence: 8, projectionKind: "message", payload: Data(0..<255),
            recipientUserIDs: [user], groupMembershipRevision: 0, acceptedMembershipRevision: UInt64.max, excludedConnectionID: UUID())
    }
    @Test func allDeliveryVariantsAndReceipts() throws {
        let fence = try fence(), event = event(), member = V2RoomSubscriptionMember(userID: user, memberRevision: 8)
        let payloads: [V2RoomSubscriptionPayload] = [.baseline(members: [member]), .baselinePage(index: 2, totalMembers: 1025, members: [member]),
            .grant(member: member, baselineSequence: 7), .broadcast(event), .event(event, members: [member]), .head(highWatermark: 0), .authorizationInvalidated, .revoke(userID: user, memberRevision: 9)]
        for payload in payloads {
            #expect(try roundTrip(V2RoomSubscriptionDeliveryBatch(deliveries: [.init(fence: fence, deliverySequence: UInt64.max, authorizationSequence: UInt64.max, payload: payload)])))
        }
        for result: V2RoomSubscriptionDeliveryResult in [.appliedThrough(0), .snapshotRequired, .stale] {
            #expect(try roundTrip(V2RoomSubscriptionBatchResult(receipts: [.init(fence: fence, result: result)])))
        }
    }
    @Test func logPullAndPage() throws {
        let pull = try V2ActorRoomLogPullWire(roomID: room, actorUserID: user, afterRoomSequence: 0, pageSize: 500)
        #expect(try roundTrip(V2RoomRequest.roomLog(.pull(pull))))
        #expect(try roundTrip(V2RoomRequest.roomLog(.subscribe(.init(roomID: room, actorUserID: user)))))
        let page = try V2ActorRoomLogPageWire(roomID: room, events: [.init(sourceEventID: .init(uuid: UUID()), roomSequence: 1, projectionKind: "m", payload: Data(0..<255))], nextRoomSequence: 1, hasMore: true, logTrimmedThroughRoomSequence: 0)
        for response: V2RoomResponse in [.roomLog(.page(page)), .roomLog(.failure(.actorNotMember)), .roomLog(.subscription(try .init(roomID: room, highWatermark: 1, membershipRevision: 0)))] { #expect(try roundTrip(response)) }
    }
    @Test func realtimePayloads() throws {
        let gateway = descriptor().identity, topic = V2RealtimeTopic(kind: .roomEvents, id: room.rawValue, owner: try .init(shardID: "rooms", epoch: 0))
        let payloads: [V2RealtimePayload] = [.roomWake(roomID: room, highWatermark: 0), .roomEvents([event()]), .userSync(userID: user, highWatermark: UInt64.max), .presence(userID: user),
            .typing(roomID: room, userID: user, isTyping: false, expiresAt: Date(), sourceConnectionID: UUID(), sequence: UInt64.max)]
        for payload in payloads {
            let delivery = V2RealtimeDelivery(topic: topic, partitionID: 2, partitionEpoch: 3, sessionID: UUID(), interestGeneration: 4, gatewayIncarnation: gateway.incarnationID, payload: payload)
            #expect(try roundTrip(V2RealtimeBatch(recipient: gateway, deliveries: [delivery])))
        }
    }
    @Test func journalVariantsAndResults() throws {
        let source = V2RealtimeJournalSource(sourceID: "journal", incarnationID: UUID(), partitionID: 255)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1, sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date(),
            routingPartitionEpoch: 2, routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 3, gatewayIncarnationID: UUID())
        let authorization = V2RealtimeJournalRoomAuthorization(roomID: room, ownerEpoch: 0, permissionVersion: 2, controlVersion: 3, viewerMembershipRevisions: [user: UInt64.max], highWatermark: 4)
        let changes: [V2RealtimeJournalProjectionChange] = [.authorization(authorization), .head(roomID: room, highWatermark: 5, ownerEpoch: 0, permissionVersion: 6), .invalidate(roomID: room),
            .controlInvalidation(roomID: room, ownerEpoch: 7, controlVersion: 8), .userControlInvalidation(userID: user, controlVersion: 9, deviceID: nil),
            .userControlInvalidation(userID: user, controlVersion: 10, deviceID: UUID(), membershipRoomID: room)]
        let payloads: [V2RealtimeJournalProjectionPayload] = [.baseline(minimumCut: 0), .snapshot(cut: 20, rooms: [authorization]),
            .changes(fromExclusive: 0, throughInclusive: 6, entries: changes.enumerated().map { .init(sequence: Int64($0.offset + 1), change: $0.element) }),
            .heads([.init(roomID: room, highWatermark: 12, ownerEpoch: 13, controlVersion: 14)])]
        for payload in payloads { #expect(try roundTrip(V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: payload))) }
        let batchID = UUID()
        let results: [V2RealtimeJournalProjectionResult] = [.applied(.init(batchID: batchID, source: source, fence: fence, appliedThrough: 20, snapshotInstalled: true)),
            .headsApplied(.init(batchID: batchID, source: source, fence: fence)), .stale, .snapshotRequired, .overloaded, .invalid]
        for result in results { #expect(try roundTrip(result)) }
        var malformed = Im_Actor_V1_HotJournalBatch(.init(source: source, fence: fence, payload: .snapshot(cut: 1, rooms: [authorization])))
        var snapshot = malformed.snapshot; snapshot.rooms[0].viewers.append(snapshot.rooms[0].viewers[0]); malformed.snapshot = snapshot
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RealtimeJournalProjectionBatch.self, from: malformed.serializedData()) }
    }
    @Test func invalidFixedPayloadsFailClosed() throws {
        let command = try send()
        var wire = Im_Actor_V1_HotRoomRequest(); wire.coldValue = try V2ActorProtobuf.encodeValue(V2RoomRequest.messaging(.sendOperation(command)))
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: wire.serializedData()) }
        wire = .init(); var sendWire = Im_Actor_V1_HotSend(command); sendWire.entities[0].kind = "unknown"; wire.send = sendWire
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: wire.serializedData()) }
        wire = .init(); var sub = Im_Actor_V1_HotSubscriptionCommand(); sub.kind = 999; wire.subscription = sub
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: wire.serializedData()) }
        var batch = Im_Actor_V1_HotDeliveryBatch(); var delivery = Im_Actor_V1_HotSubscriptionDelivery(); delivery.head = 1; batch.deliveries = [delivery]
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomSubscriptionDeliveryBatch.self, from: batch.serializedData()) }
        var unknown = Im_Actor_V1_HotSend(command); unknown.unknownFields = .init(); wire.send = unknown
        var bytes = try wire.serializedData(); bytes.append(contentsOf: [0xA0, 0x06, 1])
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(V2RoomRequest.self, from: bytes) }
    }
}
