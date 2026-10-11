import Foundation
import IMV2Core

public enum V2MessageSendOperationWireCodecError: Error, Equatable, Sendable {
    case invalidField
    case fingerprintMismatch
}

/// Converts the complete v45 send contract without depending on protobuf byte ordering.
public enum V2MessageSendOperationWireCodec {
    public static let defaultMessageLimits = try! V2MessageCommandLimits(maxUTF8Bytes: 65_536)
    public static func encode(command value: V2MessageSendOperationCommand) throws -> IMV2MessageSendOperation {
        let command = value.command
        var wire = IMV2MessageSendOperation()
        wire.roomID = command.roomID.rawValue
        wire.senderUserID = command.senderUserID.rawValue
        wire.clientMessageID = command.clientMessageID.rawValue
        wire.text = command.text
        wire.mediaIds = command.media.map { $0.mediaID.rawValue }
        wire.mentions = command.mentions.map { mention in
            var item = IMV2MessageSendMention()
            switch mention {
            case .user(let user): item.userID = user.rawValue
            case .everyone: item.everyone = true
            }
            return item
        }
        wire.entities = command.entities.map { entity in
            var item = IMV2MessageSendEntity()
            item.offsetUtf16 = UInt32(entity.offsetUTF16)
            item.lengthUtf16 = UInt32(entity.lengthUTF16)
            item.kind = entity.kind.rawValue
            if let url = entity.linkURL { item.linkURL = url.absoluteString }
            return item
        }
        if let reply = command.replyTo { wire.replyToMessageID = reply.messageID.rawValue }
        wire.firstSubmissionDeadlineMs = value.firstSubmissionDeadlineMilliseconds
        wire.domainFingerprintVersion = UInt32(command.fingerprint.version)
        wire.domainFingerprint = command.fingerprint.digest
        let fingerprint = try value.fingerprint
        wire.fingerprintVersion = UInt32(fingerprint.version)
        wire.fingerprint = fingerprint.digest
        return wire
    }

    public static func decode(command wire: IMV2MessageSendOperation, limits: V2MessageCommandLimits = defaultMessageLimits) throws -> V2MessageSendOperationCommand {
        let media = try wire.mediaIds.map { V2MediaReference(mediaID: try MediaID($0)) }
        let mentions = try wire.mentions.map { item -> V2MentionTarget in
            switch item.target {
            case .userID(let user)?: return .user(try UserID(user))
            case .everyone(true)?: return .everyone
            default: throw V2MessageSendOperationWireCodecError.invalidField
            }
        }
        let entities = try wire.entities.map { item -> V2MessageEntity in
            guard let offset = Int(exactly: item.offsetUtf16), let length = Int(exactly: item.lengthUtf16),
                  let kind = V2MessageEntity.Kind(rawValue: item.kind) else {
                throw V2MessageSendOperationWireCodecError.invalidField
            }
            let url = item.hasLinkURL ? URL(string: item.linkURL) : nil
            if item.hasLinkURL && url == nil { throw V2MessageSendOperationWireCodecError.invalidField }
            return try V2MessageEntity(offsetUTF16: offset, lengthUTF16: length, kind: kind, linkURL: url)
        }
        let reply = try wire.hasReplyToMessageID ? V2MessageReplyReference(messageID: MessageID(wire.replyToMessageID)) : nil
        let payload = try V2SendMessageCommand(
            roomID: RoomID(wire.roomID), senderUserID: UserID(wire.senderUserID),
            clientMessageID: ClientMessageID(wire.clientMessageID), text: wire.text,
            media: media, mentions: mentions, entities: entities, replyTo: reply,
            limits: limits
        )
        let value = try V2MessageSendOperationCommand(command: payload, firstSubmissionDeadlineMilliseconds: wire.firstSubmissionDeadlineMs)
        let fingerprint = try value.fingerprint
        guard wire.domainFingerprintVersion == UInt32(payload.fingerprint.version),
              wire.domainFingerprint == payload.fingerprint.digest,
              wire.fingerprintVersion == UInt32(fingerprint.version), wire.fingerprint == fingerprint.digest else {
            throw V2MessageSendOperationWireCodecError.fingerprintMismatch
        }
        return value
    }

    public static func encode(recovery value: V2MessageSendOperationRecoveryRequest) -> IMV2MessageSendOperationRecover {
        var wire = IMV2MessageSendOperationRecover()
        wire.identity = encode(identity: value.identity)
        wire.fingerprint = encode(fingerprint: value.fingerprint)
        wire.domainFingerprint = encode(fingerprint: value.domainFingerprint)
        return wire
    }

    public static func decode(recovery wire: IMV2MessageSendOperationRecover) throws -> V2MessageSendOperationRecoveryRequest {
        guard wire.hasIdentity, wire.hasFingerprint, wire.hasDomainFingerprint else { throw V2MessageSendOperationWireCodecError.invalidField }
        return try .init(identity: decode(identity: wire.identity), fingerprint: decode(fingerprint: wire.fingerprint),
                         domainFingerprint: V2SendMessageFingerprint(version: checkedUInt16(wire.domainFingerprint.version), digest: wire.domainFingerprint.digest))
    }

    public static func encode(result value: V2MessageSendOperationRecoveryResult) -> IMV2MessageSendOperationResult {
        var wire = IMV2MessageSendOperationResult()
        switch value {
        case .unresolved: wire.unresolved = true
        case .fingerprintConflict: wire.fingerprintConflict = true
        case .deferred(let hint):
            var item = IMV2MessageSendOperationRetryHint()
            item.identity = encode(identity: hint.identity)
            item.fingerprint = encode(fingerprint: hint.fingerprint)
            item.reason = hint.reason == .rateLimited ? .rateLimited : .admissionUnavailable
            if let delay = hint.retryAfterMilliseconds { item.retryAfterMs = delay }
            wire.deferred = item
        case .receipt(let receipt):
            var item = IMV2MessageSendOperationReceipt()
            item.identity = encode(identity: receipt.identity)
            item.fingerprint = encode(fingerprint: receipt.fingerprint)
            item.resolvedAtMs = receipt.resolvedAtMilliseconds
            switch receipt.outcome {
            case .accepted(let accepted):
                var outcome = IMV2MessageSendOperationAcceptance()
                outcome.messageID = accepted.messageID.rawValue
                outcome.roomSequence = accepted.roomSequence
                item.accepted = outcome
            case .rejected(let rejection):
                var outcome = IMV2MessageSendOperationRejection()
                switch rejection {
                case .expiredUnsubmitted: outcome.reason = .expiredUnsubmitted
                case .permissionDenied: outcome.reason = .permissionDenied
                case .roomNotFound: outcome.reason = .roomNotFound
                case .invalidContent: outcome.reason = .invalidContent
                case .directPolicyDenied: outcome.reason = .directPolicyDenied
                }
                item.rejected = outcome
            }
            wire.receipt = item
        }
        return wire
    }

    public static func decode(result wire: IMV2MessageSendOperationResult) throws -> V2MessageSendOperationRecoveryResult {
        switch wire.result {
        case .unresolved(true)?: return .unresolved
        case .fingerprintConflict(true)?: return .fingerprintConflict
        case .deferred(let item)?:
            guard item.hasIdentity, item.hasFingerprint else { throw V2MessageSendOperationWireCodecError.invalidField }
            let reason: V2MessageOperationRetryHint.Reason
            switch item.reason {
            case .rateLimited: reason = .rateLimited
            case .admissionUnavailable: reason = .admissionUnavailable
            default: throw V2MessageSendOperationWireCodecError.invalidField
            }
            return .deferred(try .init(identity: decode(identity: item.identity), fingerprint: decode(fingerprint: item.fingerprint),
                                       reason: reason, retryAfterMilliseconds: item.hasRetryAfterMs ? item.retryAfterMs : nil))
        case .receipt(let item)?:
            guard item.hasIdentity, item.hasFingerprint else { throw V2MessageSendOperationWireCodecError.invalidField }
            let outcome: V2MessageSendOperationTerminalOutcome
            switch item.outcome {
            case .accepted(let accepted)?: outcome = .accepted(try .init(messageID: MessageID(accepted.messageID), roomSequence: accepted.roomSequence))
            case .rejected(let rejected)?:
                let reason: V2MessageSendOperationRejection
                switch rejected.reason {
                case .expiredUnsubmitted: reason = .expiredUnsubmitted
                case .permissionDenied: reason = .permissionDenied
                case .roomNotFound: reason = .roomNotFound
                case .invalidContent: reason = .invalidContent
                case .directPolicyDenied: reason = .directPolicyDenied
                default: throw V2MessageSendOperationWireCodecError.invalidField
                }
                outcome = .rejected(reason)
            default: throw V2MessageSendOperationWireCodecError.invalidField
            }
            return .receipt(try .init(identity: decode(identity: item.identity), fingerprint: decode(fingerprint: item.fingerprint),
                                      outcome: outcome, resolvedAtMilliseconds: item.resolvedAtMs))
        default: throw V2MessageSendOperationWireCodecError.invalidField
        }
    }

    private static func encode(identity: V2OperationIdentity) -> IMV2MessageSendOperationIdentity {
        var wire = IMV2MessageSendOperationIdentity()
        wire.accountID = identity.accountID.rawValue
        if case .room(let room) = identity.scope { wire.roomID = room.rawValue }
        wire.operationID = identity.operation.rawValue
        return wire
    }
    private static func decode(identity wire: IMV2MessageSendOperationIdentity) throws -> V2OperationIdentity {
        try .init(accountID: UserID(wire.accountID), scope: .room(RoomID(wire.roomID)), operation: .sendMessage(ClientMessageID(wire.operationID)))
    }
    private static func encode(fingerprint: V2OperationFingerprint) -> IMV2MessageSendOperationFingerprint {
        var wire = IMV2MessageSendOperationFingerprint()
        wire.version = UInt32(fingerprint.version)
        wire.digest = fingerprint.digest
        return wire
    }
    private static func encode(fingerprint: V2SendMessageFingerprint) -> IMV2MessageSendOperationFingerprint {
        var wire = IMV2MessageSendOperationFingerprint()
        wire.version = UInt32(fingerprint.version)
        wire.digest = fingerprint.digest
        return wire
    }
    private static func decode(fingerprint wire: IMV2MessageSendOperationFingerprint) throws -> V2OperationFingerprint {
        try .init(version: checkedUInt16(wire.version), digest: wire.digest)
    }
    private static func checkedUInt16(_ value: UInt32) throws -> UInt16 {
        guard let value = UInt16(exactly: value) else { throw V2MessageSendOperationWireCodecError.invalidField }
        return value
    }
}
