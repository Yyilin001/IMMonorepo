import Foundation
import IMV2Core
import SwiftProtobuf

extension Im_Actor_V1_HotSubscriptionCommand {
    package init(_ value: V2RoomSubscriptionCommand) {
        self.init(); roomID = value.roomID.rawValue; userID = value.actorUserID.rawValue; gateway = .init(value.gatewayDescriptor)
        switch value {
        case .subscribe: kind = 1
        case .activate(let value): kind = 2; fence = .init(value.fence)
        case .reset(let value): kind = 3; fence = .init(value.expectedFence)
        case .unsubscribe(let value): kind = 4; memberRevision = value.memberRevision
        case .renew(let value): kind = 5; fence = .init(value.expectedFence); appliedControlSequence = value.appliedControlSequence
        }
    }
    package func model() throws -> V2RoomSubscriptionCommand {
        try V2HotPB.check(self, hasGateway)
        let room = try RoomID(roomID), user = try UserID(userID), descriptor = try gateway.model()
        switch kind {
        case 1: try V2HotPB.check(self, !hasFence && memberRevision == 0 && appliedControlSequence == 0); return .subscribe(.init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor))
        case 2: try V2HotPB.check(self, hasFence && memberRevision == 0 && appliedControlSequence == 0); return .activate(try .init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, fence: fence.model()))
        case 3: try V2HotPB.check(self, hasFence && memberRevision == 0 && appliedControlSequence == 0); return .reset(try .init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, expectedFence: fence.model()))
        case 4: try V2HotPB.check(self, !hasFence && appliedControlSequence == 0); return .unsubscribe(.init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, memberRevision: memberRevision))
        case 5: try V2HotPB.check(self, hasFence && memberRevision == 0); return .renew(try .init(roomID: room, actorUserID: user, gatewayDescriptor: descriptor, expectedFence: fence.model(), appliedControlSequence: appliedControlSequence))
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension Im_Actor_V1_HotSubscriptionResult {
    package init(_ value: V2RoomSubscriptionResult) {
        self.init()
        switch value {
        case .granted(let value):
            var lease = Im_Actor_V1_HotSubscriptionLease(); lease.fence = .init(value.fence); lease.memberRevision = value.memberRevision
            lease.baseline = value.userBaselineSequence; lease.remainingMs = value.remainingLeaseMilliseconds; granted = lease
        case .renewed(let value):
            var lease = Im_Actor_V1_HotSubscriptionLease(); lease.fence = .init(value.fence); lease.appliedControlSequence = value.appliedControlSequence
            lease.committedSequence = value.committedRoomSequence; lease.remainingMs = value.remainingLeaseMilliseconds; renewed = lease
        case .activated: activated = .init()
        case .unsubscribed: unsubscribed = .init()
        case .failure(let reason): failure = reason.rawValue
        }
    }
    package func model() throws -> V2RoomSubscriptionResult {
        try V2HotPB.check(self)
        switch outcome {
        case .granted(let value):
            try V2HotPB.check(value, value.hasFence && value.appliedControlSequence == 0 && value.committedSequence == 0)
            return .granted(try .init(fence: value.fence.model(), memberRevision: value.memberRevision, userBaselineSequence: value.baseline, remainingLeaseMilliseconds: value.remainingMs))
        case .renewed(let value):
            try V2HotPB.check(value, value.hasFence && value.memberRevision == 0 && value.baseline == 0)
            return .renewed(try .init(fence: value.fence.model(), appliedControlSequence: value.appliedControlSequence, committedRoomSequence: value.committedSequence, remainingLeaseMilliseconds: value.remainingMs))
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
        case .messaging(.sendOperation), .roomSubscription, .roomLog: true
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
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return wire
    }
    package func protobufBytes() throws -> Data { try hotWire().serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotRoomRequest(serializedBytes: bytes).model() }
}
extension Im_Actor_V1_HotRoomRequest {
    package func model() throws -> V2RoomRequest {
        try V2HotPB.check(self)
        switch operation {
        case .send(let value): return .messaging(.sendOperation(try value.model()))
        case .subscription(let value): return .roomSubscription(try value.model())
        case .logPull(let value): return .roomLog(.pull(try value.model()))
        case .logSubscribe(let value): try V2HotPB.check(value); return .roomLog(.subscribe(try .init(roomID: .init(value.roomID), actorUserID: .init(value.userID))))
        case .coldValue(let bytes):
            let value = try V2ActorProtobuf.decodeValue(V2RoomRequest.self, from: bytes)
            guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension V2RoomResponse: V2ActorProtobufMessage {
    package var usesHotProtobuf: Bool {
        switch self { case .messaging(.sendOperation), .roomSubscription, .roomLog: true; default: false }
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
        default: wire.coldValue = try V2ActorProtobuf.encodeValue(self)
        }
        return wire
    }
    package func protobufBytes() throws -> Data { try hotWire().serializedData() }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self { try Im_Actor_V1_HotRoomResponse(serializedBytes: bytes).model() }
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
        case .coldValue(let bytes): let value = try V2ActorProtobuf.decodeValue(V2RoomResponse.self, from: bytes); guard !value.usesHotProtobuf else { throw V2HotPB.Invalid.value }; return value
        default: throw V2HotPB.Invalid.value
        }
    }
}
