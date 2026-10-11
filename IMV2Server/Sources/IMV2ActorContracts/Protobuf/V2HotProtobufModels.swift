import Foundation
import IMV2Core
import SwiftProtobuf

/// Closed fixed-field adapters. Unknown fields and missing required submessages
/// fail before constructing domain values; domain initializers retain validation.
package enum V2HotPB {
    package enum Invalid: Error { case value }
    package static func check<T: Message>(_ value: T, _ condition: Bool = true) throws {
        guard condition, value.unknownFields.data.isEmpty else { throw Invalid.value }
    }
    package static func bytes(_ uuid: UUID) -> Data {
        var tuple = uuid.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
    package static func uuid(_ bytes: Data) throws -> UUID {
        guard bytes.count == 16 else { throw Invalid.value }
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
extension Im_Actor_V1_HostIdentity {
    package init(_ value: V2ActorHostIdentity) { self.init(); hostID = value.hostID.rawValue; incarnationID = V2HotPB.bytes(value.incarnationID) }
    package func model() throws -> V2ActorHostIdentity { try V2HotPB.check(self); return try .init(hostID: .init(hostID), incarnationID: V2HotPB.uuid(incarnationID)) }
}
extension Im_Actor_V1_HotOwner {
    package init(_ value: V2RoomDataOwner) { self.init(); shardID = value.shardID; epoch = value.epoch }
    package func model() throws -> V2RoomDataOwner { try V2HotPB.check(self); return try .init(shardID: shardID, epoch: epoch) }
}
extension Im_Actor_V1_HotActivation {
    package init(_ value: V2RoomActivationToken) { self.init(); roomID = value.roomID.rawValue; owner = .init(value.owner); activationEpoch = value.activationEpoch.rawValue; host = .init(value.host) }
    package func model() throws -> V2RoomActivationToken { try V2HotPB.check(self, hasOwner && hasHost); return try .init(roomID: .init(roomID), owner: owner.model(), activationEpoch: .init(activationEpoch), host: host.model()) }
}
extension Im_Actor_V1_HotGateway {
    package init(_ value: V2GatewayRealtimeIdentity) { self.init(); nodeID = value.nodeID; serviceID = value.serviceID; incarnationID = V2HotPB.bytes(value.incarnationID) }
    package func model() throws -> V2GatewayRealtimeIdentity { try V2HotPB.check(self); return try .init(nodeID: nodeID, serviceID: serviceID, incarnationID: V2HotPB.uuid(incarnationID)) }
}
extension Im_Actor_V1_HotGatewayDescriptor {
    package init(_ value: V2GatewayRealtimeDescriptor) { self.init(); identity = .init(value.identity); endpointReference = value.endpointReference; address = value.address; port = Int64(value.port) }
    package func model() throws -> V2GatewayRealtimeDescriptor { try V2HotPB.check(self, hasIdentity); return try .init(identity: identity.model(), endpointReference: endpointReference, address: address, port: Int(port)) }
}
extension Im_Actor_V1_HotFence {
    package init(_ value: V2RoomSubscriptionFence) { self.init(); activation = .init(value.activation); subscriptionID = V2HotPB.bytes(value.subscriptionID); generation = value.generation; baselineSequence = value.baselineSequence }
    package func model() throws -> V2RoomSubscriptionFence { try V2HotPB.check(self, hasActivation); return try .init(activation: activation.model(), subscriptionID: V2HotPB.uuid(subscriptionID), generation: generation, baselineSequence: baselineSequence) }
}
extension Im_Actor_V1_HotMember {
    package init(_ value: V2RoomSubscriptionMember) { self.init(); userID = value.userID.rawValue; revision = value.memberRevision }
    package func model() throws -> V2RoomSubscriptionMember { try V2HotPB.check(self); return try .init(userID: .init(userID), memberRevision: revision) }
}
extension Im_Actor_V1_HotSend {
    package init(_ value: V2MessageSendOperationCommand) {
        self.init(); let c = value.command
        roomID = c.roomID.rawValue; senderID = c.senderUserID.rawValue; clientMessageID = c.clientMessageID.rawValue
        text = c.text; mediaIds = c.media.map { $0.mediaID.rawValue }; firstSubmissionDeadlineMs = value.firstSubmissionDeadlineMilliseconds
        mentions = c.mentions.map { target in
            var item = Im_Actor_V1_HotMention()
            switch target { case .user(let user): item.userID = user.rawValue; case .everyone: item.everyone = true }; return item
        }
        entities = c.entities.map { entity in
            var item = Im_Actor_V1_HotEntity(); item.offset = Int64(entity.offsetUTF16); item.length = Int64(entity.lengthUTF16)
            item.kind = entity.kind.rawValue; if let link = entity.linkURL { item.link = link.absoluteString }; return item
        }
        if let reply = c.replyTo { replyMessageID = reply.messageID.rawValue }
    }
    package func model() throws -> V2MessageSendOperationCommand {
        try V2HotPB.check(self, mediaIds.count <= 10 && mentions.count <= 20 && entities.count <= 100)
        let mentions: [V2MentionTarget] = try self.mentions.map { value in
            try V2HotPB.check(value)
            switch value.target { case .userID(let user): return .user(try .init(user)); case .everyone(true): return .everyone; default: throw V2HotPB.Invalid.value }
        }
        let entities: [V2MessageEntity] = try self.entities.map { value in
            try V2HotPB.check(value)
            guard let kind = V2MessageEntity.Kind(rawValue: value.kind) else { throw V2HotPB.Invalid.value }
            let url: URL?
            if value.hasLink { guard let parsed = URL(string: value.link) else { throw V2HotPB.Invalid.value }; url = parsed } else { url = nil }
            return try .init(offsetUTF16: Int(value.offset), lengthUTF16: Int(value.length), kind: kind, linkURL: url)
        }
        return try .init(command: .init(roomID: .init(roomID), senderUserID: .init(senderID), clientMessageID: .init(clientMessageID),
            text: text, media: mediaIds.map { try .init(mediaID: .init($0)) }, mentions: mentions, entities: entities,
            replyTo: hasReplyMessageID ? .init(messageID: .init(replyMessageID)) : nil, limits: .init(maxUTF8Bytes: 1_048_576)),
            firstSubmissionDeadlineMilliseconds: firstSubmissionDeadlineMs)
    }
}
extension Im_Actor_V1_HotSendIdentity {
    package init(_ value: V2OperationIdentity) throws {
        self.init(); guard case .room(let room) = value.scope, case .sendMessage(let message) = value.operation else { throw V2HotPB.Invalid.value }
        accountID = value.accountID.rawValue; roomID = room.rawValue; clientMessageID = message.rawValue
    }
    package func model() throws -> V2OperationIdentity { try V2HotPB.check(self); return try .init(accountID: .init(accountID), scope: .room(.init(roomID)), operation: .sendMessage(.init(clientMessageID))) }
}
extension Im_Actor_V1_HotFingerprint {
    package init(_ value: V2OperationFingerprint) { self.init(); version = UInt32(value.version); digest = value.digest }
    package func model() throws -> V2OperationFingerprint { try V2HotPB.check(self); guard let version = UInt16(exactly: version) else { throw V2HotPB.Invalid.value }; return try .init(version: version, digest: digest) }
}
extension Im_Actor_V1_HotAccepted {
    package init(_ value: V2MessageOperationAcceptance) { self.init(); messageID = value.messageID.rawValue; roomSequence = value.roomSequence }
    package func model() throws -> V2MessageOperationAcceptance { try V2HotPB.check(self); return try .init(messageID: .init(messageID), roomSequence: roomSequence) }
}
extension Im_Actor_V1_HotSendReceipt {
    package init(_ value: V2MessageSendOperationReceipt) throws {
        self.init(); identity = try .init(value.identity); fingerprint = .init(value.fingerprint); resolvedAtMs = value.resolvedAtMilliseconds
        switch value.outcome { case .accepted(let value): accepted = .init(value); case .rejected(let value): rejected = value.rawValue }
    }
    package func model() throws -> V2MessageSendOperationReceipt {
        try V2HotPB.check(self, hasIdentity && hasFingerprint)
        let result: V2MessageSendOperationTerminalOutcome
        switch outcome {
        case .accepted(let value): result = .accepted(try value.model())
        case .rejected(let value): guard let reason = V2MessageSendOperationRejection(rawValue: value) else { throw V2HotPB.Invalid.value }; result = .rejected(reason)
        default: throw V2HotPB.Invalid.value
        }
        return try .init(identity: identity.model(), fingerprint: fingerprint.model(), outcome: result, resolvedAtMilliseconds: resolvedAtMs)
    }
}
extension Im_Actor_V1_HotSendResult {
    package init(_ value: V2MessageSendOperationRecoveryResult) throws {
        self.init()
        switch value {
        case .receipt(let value): receipt = try .init(value)
        case .deferred(let value):
            var hint = Im_Actor_V1_HotRetry(); hint.identity = try .init(value.identity); hint.fingerprint = .init(value.fingerprint); hint.reason = value.reason.rawValue
            if let after = value.retryAfterMilliseconds { hint.retryAfterMs = after }; deferred = hint
        case .unresolved: unresolved = .init()
        case .fingerprintConflict: fingerprintConflict = .init()
        }
    }
    package func model() throws -> V2MessageSendOperationRecoveryResult {
        try V2HotPB.check(self)
        switch outcome {
        case .receipt(let value): return .receipt(try value.model())
        case .deferred(let value):
            try V2HotPB.check(value, value.hasIdentity && value.hasFingerprint)
            guard let reason = V2MessageOperationRetryHint.Reason(rawValue: value.reason) else { throw V2HotPB.Invalid.value }
            return .deferred(try .init(identity: value.identity.model(), fingerprint: value.fingerprint.model(), reason: reason, retryAfterMilliseconds: value.hasRetryAfterMs ? value.retryAfterMs : nil))
        case .unresolved(let value): try V2HotPB.check(value); return .unresolved
        case .fingerprintConflict(let value): try V2HotPB.check(value); return .fingerprintConflict
        default: throw V2HotPB.Invalid.value
        }
    }
}
