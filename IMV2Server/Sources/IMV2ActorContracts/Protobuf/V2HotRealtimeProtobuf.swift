import Foundation
import IMV2Core
import SwiftProtobuf

extension Im_Actor_V1_HotEvent {
    package init(_ value: V2RealtimeRoomEvent) {
        self.init(); roomID = value.roomID.rawValue; highWatermark = value.highWatermark; eventID = value.sourceEventID.rawValue
        sequence = value.roomSequence; projectionKind = value.projectionKind; payload = value.payload
        recipientIds = value.recipientUserIDs.map(\.rawValue).sorted()
        if let revision = value.groupMembershipRevision { groupRevision = revision }
        if let revision = value.acceptedMembershipRevision { acceptedRevision = revision }
        if let excluded = value.excludedConnectionID { excludedConnection = V2HotPB.bytes(excluded) }
    }
    package func model() throws -> V2RealtimeRoomEvent {
        try V2HotPB.check(self, Set(recipientIds).count == recipientIds.count)
        return try .init(roomID: .init(roomID), highWatermark: highWatermark, sourceEventID: .init(eventID), roomSequence: sequence,
            projectionKind: projectionKind, payload: payload, recipientUserIDs: Set(recipientIds.map { try UserID($0) }),
            groupMembershipRevision: hasGroupRevision ? groupRevision : nil, acceptedMembershipRevision: hasAcceptedRevision ? acceptedRevision : nil,
            excludedConnectionID: hasExcludedConnection ? V2HotPB.uuid(excludedConnection) : nil)
    }
}
extension Im_Actor_V1_HotSubscriptionDelivery {
    package init(_ value: V2RoomSubscriptionDelivery) {
        self.init(); fence = .init(value.fence); deliverySequence = value.deliverySequence; authorizationSequence = value.authorizationSequence
        switch value.payload {
        case .baseline(let members): var v = Im_Actor_V1_HotMembers(); v.members = members.map { .init($0) }; baseline = v
        case .baselinePage(let index, let total, let members): var v = Im_Actor_V1_HotBaselinePage(); v.index = Int64(index); v.total = Int64(total); v.members = members.map { .init($0) }; baselinePage = v
        case .grant(let member, let sequence): var v = Im_Actor_V1_HotGrant(); v.member = .init(member); v.baseline = sequence; grant = v
        case .broadcast(let value): broadcast = .init(value)
        case .event(let event, let members): var v = Im_Actor_V1_HotEventMembers(); v.event = .init(event); v.members = members.map { .init($0) }; self.event = v
        case .head(let watermark): head = watermark
        case .authorizationInvalidated: invalidated = .init()
        case .revoke(let user, let revision): revoke = .init(.init(userID: user, memberRevision: revision))
        }
    }
    package func model() throws -> V2RoomSubscriptionDelivery {
        try V2HotPB.check(self, hasFence)
        let body: V2RoomSubscriptionPayload
        switch payload {
        case .baseline(let value): try V2HotPB.check(value); body = .baseline(members: try value.members.map { try $0.model() })
        case .baselinePage(let value): try V2HotPB.check(value); body = .baselinePage(index: Int(value.index), totalMembers: Int(value.total), members: try value.members.map { try $0.model() })
        case .grant(let value): try V2HotPB.check(value, value.hasMember); body = .grant(member: try value.member.model(), baselineSequence: value.baseline)
        case .broadcast(let value): body = .broadcast(try value.model())
        case .event(let value): try V2HotPB.check(value, value.hasEvent); body = .event(try value.event.model(), members: try value.members.map { try $0.model() })
        case .head(let value): body = .head(highWatermark: value)
        case .invalidated(let value): try V2HotPB.check(value); body = .authorizationInvalidated
        case .revoke(let value): let member = try value.model(); body = .revoke(userID: member.userID, memberRevision: member.memberRevision)
        default: throw V2HotPB.Invalid.value
        }
        return try .init(fence: fence.model(), deliverySequence: deliverySequence, authorizationSequence: authorizationSequence, payload: body)
    }
}
extension Im_Actor_V1_HotDeliveryResult {
    package init(_ value: V2RoomSubscriptionDeliveryResult) {
        self.init(); switch value { case .appliedThrough(let sequence): appliedThrough = sequence; case .snapshotRequired: snapshotRequired = .init(); case .stale: stale = .init() }
    }
    package func model() throws -> V2RoomSubscriptionDeliveryResult {
        try V2HotPB.check(self)
        switch result { case .appliedThrough(let sequence): return .appliedThrough(sequence); case .snapshotRequired(let value): try V2HotPB.check(value); return .snapshotRequired; case .stale(let value): try V2HotPB.check(value); return .stale; default: throw V2HotPB.Invalid.value }
    }
}
extension Im_Actor_V1_HotDeliveryBatch {
    package init(_ value: V2RoomSubscriptionDeliveryBatch) { self.init(); deliveries = value.deliveries.map { .init($0) } }
    package func model() throws -> V2RoomSubscriptionDeliveryBatch { try V2HotPB.check(self); return .init(deliveries: try deliveries.map { try $0.model() }) }
}
extension Im_Actor_V1_HotDeliveryReceipts {
    package init(_ value: V2RoomSubscriptionBatchResult) {
        self.init(); receipts = value.receipts.map { item in var v = Im_Actor_V1_HotSubscriptionReceipt(); v.fence = .init(item.fence); v.result = .init(item.result); return v }
    }
    package func model() throws -> V2RoomSubscriptionBatchResult {
        try V2HotPB.check(self)
        return .init(receipts: try receipts.map { value in try V2HotPB.check(value, value.hasFence && value.hasResult); return try .init(fence: value.fence.model(), result: value.result.model()) })
    }
}
extension Im_Actor_V1_HotTopic {
    package init(_ value: V2RealtimeTopic) { self.init(); kind = value.kind.rawValue; id = value.id; owner = .init(value.owner) }
    package func model() throws -> V2RealtimeTopic { try V2HotPB.check(self, hasOwner); guard let kind = V2RealtimeTopicKind(rawValue: kind) else { throw V2HotPB.Invalid.value }; return try .init(kind: kind, id: id, owner: owner.model()) }
}
extension Im_Actor_V1_HotRealtimePayload {
    package init(_ value: V2RealtimePayload) {
        self.init()
        switch value {
        case .roomWake(let room, let watermark): var v = Im_Actor_V1_HotRoomWake(); v.roomID = room.rawValue; v.watermark = watermark; roomWake = v
        case .roomEvents(let events): var v = Im_Actor_V1_HotEvents(); v.events = events.map { .init($0) }; roomEvents = v
        case .userSync(let user, let watermark): var v = Im_Actor_V1_HotUserSync(); v.userID = user.rawValue; v.watermark = watermark; userSync = v
        case .presence(let user): presence = user.rawValue
        case .typing(let room, let user, let typing, let expires, let connection, let sequence):
            var v = Im_Actor_V1_HotTyping(); v.roomID = room.rawValue; v.userID = user.rawValue; v.isTyping = typing
            v.expires = expires.timeIntervalSinceReferenceDate; v.connectionID = V2HotPB.bytes(connection); v.sequence = sequence; self.typing = v
        }
    }
    package func model() throws -> V2RealtimePayload {
        try V2HotPB.check(self)
        switch payload {
        case .roomWake(let value): try V2HotPB.check(value); return .roomWake(roomID: try .init(value.roomID), highWatermark: value.watermark)
        case .roomEvents(let value): try V2HotPB.check(value); return .roomEvents(try value.events.map { try $0.model() })
        case .userSync(let value): try V2HotPB.check(value); return .userSync(userID: try .init(value.userID), highWatermark: value.watermark)
        case .presence(let user): return .presence(userID: try .init(user))
        case .typing(let value): try V2HotPB.check(value, value.expires.isFinite); return .typing(roomID: try .init(value.roomID), userID: try .init(value.userID), isTyping: value.isTyping, expiresAt: .init(timeIntervalSinceReferenceDate: value.expires), sourceConnectionID: try V2HotPB.uuid(value.connectionID), sequence: value.sequence)
        default: throw V2HotPB.Invalid.value
        }
    }
}
extension Im_Actor_V1_HotRealtimeBatch {
    package init(_ value: V2RealtimeBatch) {
        self.init(); batchID = V2HotPB.bytes(value.batchID); recipient = .init(value.recipient)
        deliveries = value.deliveries.map { item in
            var v = Im_Actor_V1_HotRealtimeDelivery(); v.topic = .init(item.topic); v.partitionID = Int64(item.partitionID); v.partitionEpoch = item.partitionEpoch
            v.sessionID = V2HotPB.bytes(item.sessionID); v.interestGeneration = item.interestGeneration; v.gatewayIncarnation = V2HotPB.bytes(item.gatewayIncarnation); v.payload = .init(item.payload); return v
        }
    }
    package func model() throws -> V2RealtimeBatch {
        try V2HotPB.check(self, hasRecipient)
        let items: [V2RealtimeDelivery] = try deliveries.map { value in
            try V2HotPB.check(value, value.hasTopic && value.hasPayload)
            return try .init(topic: value.topic.model(), partitionID: Int(value.partitionID), partitionEpoch: value.partitionEpoch, sessionID: V2HotPB.uuid(value.sessionID), interestGeneration: value.interestGeneration, gatewayIncarnation: V2HotPB.uuid(value.gatewayIncarnation), payload: value.payload.model())
        }
        return try .init(batchID: V2HotPB.uuid(batchID), recipient: recipient.model(), deliveries: items)
    }
}
