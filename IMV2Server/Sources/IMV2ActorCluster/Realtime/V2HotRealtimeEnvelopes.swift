import Foundation
import IMV2ActorContracts
import SwiftProtobuf

private func callHeader(service: V2ActorServiceID, version: Int, incarnation: UUID, recipient: V2GatewayRealtimeIdentity,
                        session: UUID, sequence: UInt64, attempt: UUID) -> Im_Actor_V1_HotRealtimeHeader {
    var h = Im_Actor_V1_HotRealtimeHeader(); h.serviceID = service.rawValue; h.version = Int64(version)
    h.callerIncarnation = V2HotPB.bytes(incarnation); h.recipient = .init(recipient)
    h.sessionID = V2HotPB.bytes(session); h.sequence = sequence; h.attemptID = V2HotPB.bytes(attempt); return h
}
private func replyHeader(recipient: V2GatewayRealtimeIdentity, session: UUID, sequence: UInt64, attempt: UUID) -> Im_Actor_V1_HotRealtimeHeader {
    var h = Im_Actor_V1_HotRealtimeHeader(); h.recipient = .init(recipient); h.sessionID = V2HotPB.bytes(session)
    h.sequence = sequence; h.attemptID = V2HotPB.bytes(attempt); return h
}
private func validate(_ h: Im_Actor_V1_HotRealtimeHeader, reply: Bool = false) throws {
    try V2HotPB.check(h, h.hasRecipient)
    if reply { try V2HotPB.check(h, h.serviceID.isEmpty && h.version == 0 && h.callerIncarnation.isEmpty) }
}

extension RoomSubscriptionCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotSubscriptionCall()
        wire.header = callHeader(service: serviceID, version: version, incarnation: callerIncarnation, recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.delivery = Im_Actor_V1_HotSubscriptionDelivery(delivery)
        wire.sourceShardID = sourceShardID
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotSubscriptionCall(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasDelivery); let h = wire.header; try validate(h)
        return try .init(serviceID: .init(h.serviceID), version: Int(h.version), callerIncarnation: V2HotPB.uuid(h.callerIncarnation),
            recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID),
            sourceShardID: wire.sourceShardID,
            delivery: wire.delivery.model())
    }
}

extension RoomSubscriptionBatchCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotSubscriptionBatchCall()
        wire.header = callHeader(service: serviceID, version: version, incarnation: callerIncarnation, recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.batch = Im_Actor_V1_HotDeliveryBatch(batch)
        wire.sourceShardID = sourceShardID
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotSubscriptionBatchCall(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasBatch); let h = wire.header; try validate(h)
        return try .init(serviceID: .init(h.serviceID), version: Int(h.version), callerIncarnation: V2HotPB.uuid(h.callerIncarnation),
            recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID),
            sourceShardID: wire.sourceShardID,
            batch: wire.batch.model())
    }
}

extension RealtimeCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotRealtimeCall()
        wire.header = callHeader(service: serviceID, version: version, incarnation: callerIncarnation, recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.batch = Im_Actor_V1_HotRealtimeBatch(batch)
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotRealtimeCall(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasBatch); let h = wire.header; try validate(h)
        return try .init(serviceID: .init(h.serviceID), version: Int(h.version), callerIncarnation: V2HotPB.uuid(h.callerIncarnation),
            recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID),
            batch: wire.batch.model())
    }
}

extension RoomSubscriptionReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotSubscriptionReply(); wire.header = replyHeader(recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.result = Im_Actor_V1_HotDeliveryResult(result)
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotSubscriptionReply(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasResult); let h = wire.header; try validate(h, reply: true)
        return try .init(recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence,
            attemptID: V2HotPB.uuid(h.attemptID), result: wire.result.model())
    }
}

extension RoomSubscriptionBatchReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotSubscriptionBatchReply(); wire.header = replyHeader(recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.result = Im_Actor_V1_HotDeliveryReceipts(result)
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotSubscriptionBatchReply(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasResult); let h = wire.header; try validate(h, reply: true)
        return try .init(recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence,
            attemptID: V2HotPB.uuid(h.attemptID), result: wire.result.model())
    }
}

extension RealtimeReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotRealtimeReply(); wire.header = replyHeader(recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.acceptance = acceptance.rawValue
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotRealtimeReply(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader); let h = wire.header; try validate(h, reply: true)
        guard let acceptance = V2RealtimeAcceptance(rawValue: wire.acceptance) else { throw V2HotPB.Invalid.value }
        return try .init(recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence,
            attemptID: V2HotPB.uuid(h.attemptID), acceptance: acceptance)
    }
}

extension JournalProjectionCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotJournalCall()
        wire.header = callHeader(service: serviceID, version: version, incarnation: callerIncarnation, recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.batch = .init(batch); return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotJournalCall(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasBatch); let h = wire.header; try validate(h)
        return try .init(serviceID: .init(h.serviceID), version: Int(h.version), callerIncarnation: V2HotPB.uuid(h.callerIncarnation), recipient: h.recipient.model(),
            sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID), batch: wire.batch.model())
    }
}
extension JournalProjectionReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotJournalReply(); wire.header = replyHeader(recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.result = .init(result); return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotJournalReply(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasResult); let h = wire.header; try validate(h, reply: true)
        return try .init(recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID), result: wire.result.model())
    }
}
extension ShardCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotShardCall()
        wire.header = callHeader(service: serviceID, version: version, incarnation: callerIncarnation, recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        switch operation {
        case .publish(let request):
            var v = Im_Actor_V1_HotPublish(); var token = Im_Actor_V1_HotShardToken()
            token.partitionID = Int64(request.token.partitionID); token.host = .init(request.token.host); token.epoch = request.token.epoch; token.leaseToken = V2HotPB.bytes(request.token.leaseToken)
            v.token = token; v.topic = .init(request.topic); v.payload = .init(request.payload); wire.publish = v
        case .control(let request): wire.coldControl = try V2ActorProtobuf.encodeValue(request)
        }
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotShardCall(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader); let h = wire.header; try validate(h)
        let operation: ShardOperation
        switch wire.operation {
        case .publish(let value):
            try V2HotPB.check(value, value.hasToken && value.hasTopic && value.hasPayload); let t = value.token; try V2HotPB.check(t, t.hasHost)
            operation = .publish(try .init(token: .init(partitionID: Int(t.partitionID), host: t.host.model(), epoch: t.epoch, leaseToken: V2HotPB.uuid(t.leaseToken)), topic: value.topic.model(), payload: value.payload.model()))
        case .coldControl(let bytes): operation = .control(try V2ActorProtobuf.decodeValue(V2RealtimeShardControlRequest.self, from: bytes))
        default: throw V2HotPB.Invalid.value
        }
        return try .init(serviceID: .init(h.serviceID), version: Int(h.version), callerIncarnation: V2HotPB.uuid(h.callerIncarnation), recipient: h.recipient.model(),
            sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID), operation: operation)
    }
}
extension ShardReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotShardReply(); wire.header = replyHeader(recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        switch result { case .publish(let value): wire.publish = value.rawValue; case .control(let value): wire.coldControl = try V2ActorProtobuf.encodeValue(value) }
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotShardReply(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader); let h = wire.header; try validate(h, reply: true)
        let result: ShardResult
        switch wire.result {
        case .publish(let value): guard let resultValue = V2RealtimeShardPublishReply(rawValue: value) else { throw V2HotPB.Invalid.value }; result = .publish(resultValue)
        case .coldControl(let bytes): result = .control(try V2ActorProtobuf.decodeValue(V2RealtimeShardControlReply.self, from: bytes))
        default: throw V2HotPB.Invalid.value
        }
        return try .init(recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID), result: result)
    }
}

extension RoomDeliverySessionCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotDeliverySessionCall()
        wire.header = callHeader(service: serviceID, version: version, incarnation: callerIncarnation,
            recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.sourceShardID = sourceShardID
        wire.pulse.session = .init(pulse.session); wire.pulse.kind = pulse.kind.rawValue; wire.pulse.sequence = pulse.sequence
        return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotDeliverySessionCall(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader && wire.hasPulse)
        try V2HotPB.check(wire.pulse, wire.pulse.hasSession)
        guard let kind = V2RoomDeliverySessionPulse.Kind(rawValue: wire.pulse.kind) else { throw V2HotPB.Invalid.value }
        let h = wire.header; try validate(h)
        return try .init(serviceID: .init(h.serviceID), version: Int(h.version), callerIncarnation: V2HotPB.uuid(h.callerIncarnation),
            recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence, attemptID: V2HotPB.uuid(h.attemptID),
            sourceShardID: wire.sourceShardID, pulse: .init(session: wire.pulse.session.model(), kind: kind, sequence: wire.pulse.sequence))
    }
}
extension RoomDeliverySessionReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var wire = Im_Actor_V1_HotDeliverySessionReply()
        wire.header = replyHeader(recipient: recipient, session: sessionID, sequence: sequence, attempt: attemptID)
        wire.result = result.rawValue; return try wire.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: borrowing RawSpan) throws -> Self {
        let wire = try Im_Actor_V1_HotDeliverySessionReply(serializedBytes: copy bytes)
        try V2HotPB.check(wire, wire.hasHeader)
        guard let result = V2RoomDeliverySessionResult(rawValue: wire.result) else { throw V2HotPB.Invalid.value }
        let h = wire.header; try validate(h, reply: true)
        return try .init(recipient: h.recipient.model(), sessionID: V2HotPB.uuid(h.sessionID), sequence: h.sequence,
            attemptID: V2HotPB.uuid(h.attemptID), result: result)
    }
}
