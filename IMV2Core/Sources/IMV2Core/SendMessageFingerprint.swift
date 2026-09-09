import Crypto
import Foundation

/// Server-derived identity of the original send intent, independent of the
/// message's editable projection. Constructed with the validated command so
/// storage adapters can bind a fixed-size value without hashing under locks.
public struct V2SendMessageFingerprint: Equatable, Encodable, Sendable {
    public static let currentVersion: UInt16 = 2
    /// Ordinary sends retain their original encoding and durable replay keys.
    public static let ordinarySendVersion: UInt16 = 1
    public let version: UInt16
    public let digest: Data

    public init(version: UInt16, digest: Data) throws {
        guard (version == Self.ordinarySendVersion || version == Self.currentVersion), digest.count == 32 else {
            throw V2SendMessageFingerprintError.invalidStoredFingerprint
        }
        self.version = version
        self.digest = digest
    }

    init(
        roomID: RoomID,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference],
        mentions: [V2MentionTarget],
        entities: [V2MessageEntity],
        replyTo: V2MessageReplyReference?,
        targetRule: FanoutTargetRule,
        forwardedFrom: V2ForwardMessageSource?
    ) {
        let version = forwardedFrom == nil ? Self.ordinarySendVersion : Self.currentVersion
        var encoder = SendMessageFingerprintEncoder()
        encoder.string("im.v2.send-message")
        encoder.integer(UInt64(version))
        encoder.string(roomID.rawValue)
        encoder.string(senderUserID.rawValue)
        encoder.string(clientMessageID.rawValue)
        // Preserve exact accepted UTF-8, including whitespace and Unicode
        // composition. Do not silently normalize content only for deduplication.
        encoder.string(text)
        encoder.integer(UInt64(media.count))
        for item in media { encoder.string(item.mediaID.rawValue) }
        encoder.integer(UInt64(mentions.count))
        for mention in mentions {
            switch mention {
            case .user(let userID):
                encoder.tag(1)
                encoder.string(userID.rawValue)
            case .everyone:
                encoder.tag(2)
            }
        }
        encoder.integer(UInt64(entities.count))
        for entity in entities {
            encoder.integer(UInt64(entity.offsetUTF16))
            encoder.integer(UInt64(entity.lengthUTF16))
            encoder.string(entity.kind.rawValue)
            encoder.optionalString(entity.linkURL?.absoluteString)
        }
        encoder.optionalString(replyTo?.messageID.rawValue)
        switch targetRule {
        case .eligibleMemberCount:
            encoder.tag(1)
        case .exactTargetCount(let count):
            encoder.tag(2)
            encoder.integer(UInt64(count))
        }
        if let forwardedFrom {
            encoder.tag(1)
            encoder.string(forwardedFrom.messageID.rawValue)
            encoder.string(forwardedFrom.senderUserID.rawValue)
            encoder.integer(forwardedFrom.sourceRevision.rawValue)
        } else {
            encoder.tag(0)
        }
        self.version = version
        self.digest = Data(encoder.hasher.finalize())
    }
}

public enum V2SendMessageFingerprintError: Error, Equatable, Sendable {
    case invalidStoredFingerprint
}

/// Version 1 uses big-endian uint64 lengths/counts, single-byte variant and
/// presence tags, and length-prefixed UTF-8. All arrays preserve command order,
/// matching the current persisted/wire intent contract. No JSON key order,
/// platform-native integer layout, randomized Hasher, or delimiter escaping.
private struct SendMessageFingerprintEncoder {
    var hasher = SHA256()

    mutating func tag(_ value: UInt8) {
        hasher.update(data: [value])
    }

    mutating func integer(_ value: UInt64) {
        var bytes = value.bigEndian
        withUnsafeBytes(of: &bytes) { hasher.update(bufferPointer: $0) }
    }

    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        integer(UInt64(bytes.count))
        hasher.update(data: bytes)
    }

    mutating func optionalString(_ value: String?) {
        if let value {
            tag(1)
            string(value)
        } else {
            tag(0)
        }
    }
}
