import Foundation
import IMV2Core
import SwiftProtobuf

extension Im_Actor_V1_HotDeliverySession {
    package init(_ value: V2RoomDeliverySession) { self.init(); host = .init(value.host); gateway = .init(value.gateway); generation = value.generation }
    package func model() throws -> V2RoomDeliverySession {
        try V2HotPB.check(self, hasHost && hasGateway)
        let value = try V2RoomDeliverySession(host: host.model(), gateway: gateway.model(), generation: generation)
        try value.validate(); return value
    }
}
extension Im_Actor_V1_HotSubscriptionCommand {
    package init(_ value: V2RoomSubscriptionCommand) {
        self.init(); roomID = value.roomID.rawValue; userID = value.actorUserID.rawValue; gateway = .init(value.gatewayDescriptor)
        switch value {
        case .subscribe: kind = 1
        case .activate(let value): kind = 2; fence = .init(value.fence)
        case .reset(let value): kind = 3; fence = .init(value.expectedFence)
        case .unsubscribe(let value): kind = 4; memberRevision = value.memberRevision
        }
    }
    package func model() throws -> V2RoomSubscriptionCommand {
        try V2HotPB.check(self, hasGateway)
        let room = try RoomID(roomID), user = try UserID(userID), descriptor = try gateway.model()
        switch kind {
        case 1: try V2HotPB.check(self, !hasFence && memberRevision == 0); return .subscribe(.init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor))
        case 2: try V2HotPB.check(self, hasFence && memberRevision == 0); return .activate(try .init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, fence: fence.model()))
        case 3: try V2HotPB.check(self, hasFence && memberRevision == 0); return .reset(try .init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, expectedFence: fence.model()))
        case 4: try V2HotPB.check(self, !hasFence); return .unsubscribe(.init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, memberRevision: memberRevision))
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension Im_Actor_V1_HotSubscriptionResult {
    package init(_ value: V2RoomSubscriptionResult) {
        self.init()
        switch value {
        case .granted(let value):
            var item = Im_Actor_V1_HotSubscriptionGrant(); item.fence = .init(value.fence); item.memberRevision = value.memberRevision
            item.baseline = value.userBaselineSequence; item.session = .init(value.deliverySession); granted = item
        case .activated: activated = .init()
        case .unsubscribed: unsubscribed = .init()
        case .failure(let reason): failure = reason.rawValue
        }
    }
    package func model() throws -> V2RoomSubscriptionResult {
        try V2HotPB.check(self)
        switch outcome {
        case .granted(let value):
            try V2HotPB.check(value, value.hasFence && value.hasSession)
            return .granted(try .init(fence: value.fence.model(), memberRevision: value.memberRevision, userBaselineSequence: value.baseline, deliverySession: value.session.model()))
        case .activated(let value): try V2HotPB.check(value); return .activated
        case .unsubscribed(let value): try V2HotPB.check(value); return .unsubscribed
        case .failure(let value): guard let reason = V2RoomSubscriptionFailure(rawValue: value) else { throw V2HotPB.Invalid.value }; return .failure(reason)
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension Im_Actor_V1_HotLogPull {
    package init(_ value: V2ActorRoomLogPullWire) { self.init(); roomID = value.roomID.rawValue; userID = value.actorUserID.rawValue; afterSequence = value.afterRoomSequence; pageSize = Int64(value.pageSize) }
    package func model() throws -> V2ActorRoomLogPullWire { try V2HotPB.check(self); return try .init(roomID: .init(roomID), actorUserID: .init(userID), afterRoomSequence: afterSequence, pageSize: Int(pageSize)) }
}
extension Im_Actor_V1_HotLogEntry {
    package init(_ value: V2ActorRoomLogEntryWire) { self.init(); eventID = value.sourceEventID.rawValue; sequence = value.roomSequence; projectionKind = value.projectionKind; payload = value.payload }
    package func model() throws -> V2ActorRoomLogEntryWire { try V2HotPB.check(self); return try .init(sourceEventID: .init(eventID), roomSequence: sequence, projectionKind: projectionKind, payload: payload) }
}
extension Im_Actor_V1_HotLogPage {
    package init(_ value: V2ActorRoomLogPageWire) { self.init(); roomID = value.roomID.rawValue; events = value.events.map { .init($0) }; nextSequence = value.nextRoomSequence; hasMore_p = value.hasMore; trimmedThrough = value.logTrimmedThroughRoomSequence }
    package func model() throws -> V2ActorRoomLogPageWire { try V2HotPB.check(self, events.count <= V2ActorRoomLogPullWire.maximumPageSize); return try .init(roomID: .init(roomID), events: events.map { try $0.model() }, nextRoomSequence: nextSequence, hasMore: hasMore_p, logTrimmedThroughRoomSequence: trimmedThrough) }
}
extension V2RoomRequest: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool {
        switch self {
        case .messaging(.sendOperation), .roomSubscription, .roomLog,
             .mediaAuthorization(.profileVisibilityBatch), .mediaAuthorization(.profileVisibilityCohort): true
        default: false
        }
    }
    package func hotWire() throws -> Im_Actor_V1_HotRoomRequest {
        var wire = Im_Actor_V1_HotRoomRequest()
        switch self {
        case .messaging(.sendOperation(let value)): wire.send = .init(value)
        case .roomSubscription(let value): wire.subscription = .init(value)
        case .roomLog(.pull(let value)): wire.logPull = .init(value)
        case .roomLog(.subscribe(let value)):
            var item = Im_Actor_V1_HotLogSubscribe(); item.roomID = value.roomID.rawValue; item.userID = value.actorUserID.rawValue; wire.logSubscribe = item
        case .mediaAuthorization(.profileVisibilityBatch(let value)): wire.profileRead = .init(value)
        case .mediaAuthorization(.profileVisibilityCohort(let value)): wire.profileCohort = .init(value)
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return wire
    }
    package func protobufBytes() throws -> Data { try hotWire().serializedData() }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self { try Im_Actor_V1_HotRoomRequest(serializedBytes: copy bytes).model() }
}
extension Im_Actor_V1_HotRoomRequest {
    package func model() throws -> V2RoomRequest {
        try V2HotPB.check(self)
        switch operation {
        case .send(let value): return .messaging(.sendOperation(try value.model()))
        case .subscription(let value): return .roomSubscription(try value.model())
        case .logPull(let value): return .roomLog(.pull(try value.model()))
        case .logSubscribe(let value): try V2HotPB.check(value); return .roomLog(.subscribe(try .init(roomID: .init(value.roomID), actorUserID: .init(value.userID))))
        case .profileRead(let value): return .mediaAuthorization(.profileVisibilityBatch(try value.model()))
        case .profileCohort(let value): return .mediaAuthorization(.profileVisibilityCohort(try value.model()))
        case .coldValue(let bytes):
            let value = try V2ActorProtobuf.decodeValue(V2RoomRequest.self, from: bytes)
            guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension V2RoomResponse: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool {
        switch self {
        case .messaging(.sendOperation), .roomSubscription, .roomLog,
             .mediaAuthorization(.profilesVisible), .mediaAuthorization(.profilesVisibleCohort): true
        default: false
        }
    }
    package func hotWire() throws -> Im_Actor_V1_HotRoomResponse {
        var wire = Im_Actor_V1_HotRoomResponse()
        switch self {
        case .messaging(.sendOperation(let value)): wire.send = try .init(value)
        case .roomSubscription(let value): wire.subscription = .init(value)
        case .roomLog(.page(let value)): wire.logPage = .init(value)
        case .roomLog(.subscription(let value)):
            var item = Im_Actor_V1_HotLogSubscription(); item.roomID = value.roomID.rawValue; item.highWatermark = value.highWatermark; item.membershipRevision = value.membershipRevision; wire.logSubscription = item
        case .roomLog(.failure(let value)): wire.logFailure = value.rawValue
        case .mediaAuthorization(.profilesVisible(let value)): wire.profileSnapshot = .init(value)
        case .mediaAuthorization(.profilesVisibleCohort(let values)): wire.profileSnapshots = .init(values)
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return wire
    }
    package func protobufBytes() throws -> Data { try hotWire().serializedData() }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self { try Im_Actor_V1_HotRoomResponse(serializedBytes: copy bytes).model() }
}
extension Im_Actor_V1_HotRoomResponse {
    package func model() throws -> V2RoomResponse {
        try V2HotPB.check(self)
        switch result {
        case .send(let value): return .messaging(.sendOperation(try value.model()))
        case .subscription(let value): return .roomSubscription(try value.model())
        case .logPage(let value): return .roomLog(.page(try value.model()))
        case .logSubscription(let value): try V2HotPB.check(value); return .roomLog(.subscription(try .init(roomID: .init(value.roomID), highWatermark: value.highWatermark, membershipRevision: value.membershipRevision)))
        case .logFailure(let value): guard let reason = V2ActorRoomLogFailureWire(rawValue: value) else { throw V2HotPB.Invalid.value }; return .roomLog(.failure(reason))
        case .profileSnapshot(let value): return .mediaAuthorization(.profilesVisible(try value.model()))
        case .profileSnapshots(let value): return .mediaAuthorization(.profilesVisibleCohort(try value.model()))
        case .coldValue(let bytes): let value = try V2ActorProtobuf.decodeValue(V2RoomResponse.self, from: bytes); guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}

// Count the generated log-page traversal without serializing payload buffers.
// This visitor is deliberately scoped to HotLogPage's strings, bytes, uint64,
// bool and repeated messages; it is not a general protobuf encoder.
extension V2ActorRoomLogPageWire {
    package func protobufResponseByteCount() throws -> Int {
        var visitor = V2LogPageSizeVisitor()
        try Im_Actor_V1_HotLogPage(self).traverse(visitor: &visitor)
        return 1 + V2LogPageSizeVisitor.varint(UInt64(visitor.count)) + visitor.count
    }
}
private struct V2LogPageSizeVisitor: SwiftProtobuf.Visitor {
    var count = 0
    static func varint(_ value: UInt64) -> Int {
        max(1, (64 - value.leadingZeroBitCount + 6) / 7)
    }
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {
        count += Self.varint(UInt64(fieldNumber << 3)) + Self.varint(value)
    }
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {
        count += Self.varint(UInt64(fieldNumber << 3)) + 1
    }
    private mutating func bytes(_ length: Int, fieldNumber: Int) {
        count += Self.varint(UInt64(fieldNumber << 3 | 2)) + Self.varint(UInt64(length)) + length
    }
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {
        bytes(value.utf8.count, fieldNumber: fieldNumber)
    }
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {
        bytes(value.count, fieldNumber: fieldNumber)
    }
    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        var nested = Self(); try value.traverse(visitor: &nested)
        bytes(nested.count, fieldNumber: fieldNumber)
    }
    mutating func visitMapField<K, V: SwiftProtobuf.MapValueType>(fieldType: SwiftProtobuf._ProtobufMap<K, V>.Type,
        value: SwiftProtobuf._ProtobufMap<K, V>.BaseType, fieldNumber: Int) throws { throw V2HotPB.Invalid.value }
    mutating func visitMapField<K, V>(fieldType: SwiftProtobuf._ProtobufEnumMap<K, V>.Type,
        value: SwiftProtobuf._ProtobufEnumMap<K, V>.BaseType, fieldNumber: Int) throws where V.RawValue == Int { throw V2HotPB.Invalid.value }
    mutating func visitMapField<K, V>(fieldType: SwiftProtobuf._ProtobufMessageMap<K, V>.Type,
        value: SwiftProtobuf._ProtobufMessageMap<K, V>.BaseType, fieldNumber: Int) throws { throw V2HotPB.Invalid.value }
    mutating func visitUnknown(bytes: Data) throws { count += bytes.count }
    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws { throw V2HotPB.Invalid.value }
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws { throw V2HotPB.Invalid.value }
    mutating func visitSingularEnumField<E: SwiftProtobuf.Enum>(value: E, fieldNumber: Int) throws { throw V2HotPB.Invalid.value }
}
