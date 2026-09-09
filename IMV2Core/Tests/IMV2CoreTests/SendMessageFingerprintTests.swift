import Foundation
import Testing
@testable import IMV2Core

struct SendMessageFingerprintTests {
    @Test("Ordinary v1 and versioned forward v2 match independent Python SHA-256 vectors")
    func fixedEncodingVectors() throws {
        let plain = try V2SendMessageCommand(
            roomID: RoomID("room-1"), senderUserID: UserID("user-1"),
            clientMessageID: ClientMessageID("client-1"), text: "hello",
            limits: .init(maxUTF8Bytes: 128)
        )
        #expect(hex(plain.fingerprint.digest) == "b9dd74c465574e6befa5331282391eebe346e5ee5990ef4dba904001f1e25016")
        #expect(hex(try Fixture().command().fingerprint.digest) == "8572cfa8437d7d1ac1dcfb28ad47cb3d83e77db26b6325bf16ab10db02b59f6d")
        #expect(plain.fingerprint.version == 1)
        let forward = try Fixture().command().fingerprint
        #expect(forward.version == 2)
        #expect(try V2SendMessageFingerprint(version: 2, digest: forward.digest) == forward)
        #expect(try V2SendMessageFingerprint(version: 1, digest: plain.fingerprint.digest) == plain.fingerprint)
    }

    enum Change: CaseIterable {
        case room, sender, client, text, mediaIdentity, mediaOrder, mentionsIdentity, mentionsOrder
        case everyone, entityOffset, entityLength, entityKind, entityLink, entityOrder
        case reply, noReply, targetRule, targetCount, forwardMessage, forwardSender, forwardRevision, noForward
    }

    @Test(arguments: Change.allCases)
    func everyBusinessFieldAffectsIdentity(_ change: Change) throws {
        let original = try Fixture()
        var changed = original
        switch change {
        case .room: changed.roomID = try RoomID("room-2")
        case .sender: changed.senderID = try UserID("user-3")
        case .client: changed.clientID = try ClientMessageID("client-2")
        case .text: changed.text = "hello World"
        case .mediaIdentity: changed.media[0] = .init(mediaID: try MediaID("media-c"))
        case .mediaOrder: changed.media.reverse()
        case .mentionsIdentity: changed.mentions[0] = .user(try UserID("user-3"))
        case .mentionsOrder: changed.mentions.reverse()
        case .everyone: changed.mentions.removeLast()
        case .entityOffset: changed.entities[0] = try .init(offsetUTF16: 1, lengthUTF16: 5, kind: .bold)
        case .entityLength: changed.entities[0] = try .init(offsetUTF16: 0, lengthUTF16: 4, kind: .bold)
        case .entityKind: changed.entities[0] = try .init(offsetUTF16: 0, lengthUTF16: 5, kind: .italic)
        case .entityLink: changed.entities[1] = try .init(offsetUTF16: 6, lengthUTF16: 5, kind: .link, linkURL: URL(string: "https://example.com/a?x=2"))
        case .entityOrder: changed.entities.reverse()
        case .reply: changed.reply = .init(messageID: try MessageID("message-1"))
        case .noReply: changed.reply = nil
        case .targetRule: changed.targetRule = .eligibleMemberCount
        case .targetCount: changed.targetRule = .exactTargetCount(3)
        case .forwardMessage: changed.forward = .init(messageID: try MessageID("message-8"), senderUserID: try UserID("user-9"), sourceRevision: try .init(1))
        case .forwardSender: changed.forward = .init(messageID: try MessageID("message-9"), senderUserID: try UserID("user-8"), sourceRevision: try .init(1))
        case .forwardRevision: changed.forward = .init(messageID: try MessageID("message-9"), senderUserID: try UserID("user-9"), sourceRevision: try .init(3))
        case .noForward: changed.forward = nil
        }
        #expect(try original.command().fingerprint != changed.command().fingerprint)
    }

    @Test
    func canonicalUUIDSpellingAndExactUTF8() throws {
        var fixture = try Fixture()
        fixture.roomID = try RoomID("abcdefab-1234-5678-abcd-abcdefabcdef")
        let lower = try fixture.command().fingerprint
        fixture.roomID = try RoomID("ABCDEFAB-1234-5678-ABCD-ABCDEFABCDEF")
        #expect(try fixture.command().fingerprint == lower)

        fixture.entities = []
        fixture.text = "\u{e9}"
        let composed = try fixture.command().fingerprint
        fixture.text = "e\u{301}"
        #expect(try fixture.command().fingerprint != composed)
        fixture.text = "hello\u{0}world"
        let nul = try fixture.command().fingerprint
        fixture.text = "helloworld"
        #expect(try fixture.command().fingerprint != nul)
    }

    @Test
    func fieldBoundariesCannotCollideByConcatenation() throws {
        var fixture = try Fixture()
        fixture.roomID = try RoomID("ab")
        fixture.senderID = try UserID("c")
        let first = try fixture.command().fingerprint
        fixture.roomID = try RoomID("a")
        fixture.senderID = try UserID("bc")
        #expect(try fixture.command().fingerprint != first)
    }

    @Test
    func malformedStoredFingerprintsAndNegativeTargetAreRejected() throws {
        for size in [0, 31, 33] {
            #expect(throws: V2SendMessageFingerprintError.invalidStoredFingerprint) {
                try V2SendMessageFingerprint(version: 1, digest: Data(repeating: 0, count: size))
            }
        }
        for version: UInt16 in [0, 3, .max] {
            #expect(throws: V2SendMessageFingerprintError.invalidStoredFingerprint) {
                try V2SendMessageFingerprint(version: version, digest: Data(repeating: 0, count: 32))
            }
        }
        var fixture = try Fixture()
        fixture.targetRule = .exactTargetCount(-1)
        #expect(throws: V2CoreError.invalidNonNegativeValue) { try fixture.command() }
    }

    @Test(arguments: [
        "{\"offsetUTF16\":9223372036854775807,\"lengthUTF16\":1,\"kind\":\"bold\"}",
        "{\"offsetUTF16\":1,\"lengthUTF16\":9223372036854775807,\"kind\":\"bold\"}",
        "{\"offsetUTF16\":-1,\"lengthUTF16\":1,\"kind\":\"bold\"}",
        "{\"offsetUTF16\":0,\"lengthUTF16\":0,\"kind\":\"bold\"}",
        "{\"offsetUTF16\":0,\"lengthUTF16\":1,\"kind\":\"link\",\"linkURL\":\"file:///private/a\"}"
    ])
    func decodedEntityCannotBypassCommandValidation(_ json: String) throws {
        var fixture = try Fixture()
        fixture.entities = [try JSONDecoder().decode(V2MessageEntity.self, from: Data(json.utf8))]
        #expect(throws: V2RichMessageContentError.invalidEntity) { try fixture.command() }
    }

    @Test
    func roomIsPartOfOperationKey() throws {
        let sender = try UserID("user-1")
        let client = try ClientMessageID("client-1")
        let first = V2CommandDeduplicationKey(roomID: try RoomID("room-1"), senderUserID: sender, clientMessageID: client)
        let second = V2CommandDeduplicationKey(roomID: try RoomID("room-2"), senderUserID: sender, clientMessageID: client)
        #expect(Set([first, second]).count == 2)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        var roomID: RoomID
        var senderID: UserID
        var clientID: ClientMessageID
        var text = "hello world"
        var media: [V2MediaReference]
        var mentions: [V2MentionTarget]
        var entities: [V2MessageEntity]
        var reply: V2MessageReplyReference?
        var targetRule: FanoutTargetRule = .exactTargetCount(2)
        var forward: V2ForwardMessageSource?

        init() throws {
            roomID = try RoomID("room-1")
            senderID = try UserID("user-1")
            clientID = try ClientMessageID("client-1")
            media = try ["media-a", "media-b"].map { .init(mediaID: try MediaID($0)) }
            mentions = [.user(try UserID("user-2")), .everyone]
            entities = [
                try .init(offsetUTF16: 0, lengthUTF16: 5, kind: .bold),
                try .init(offsetUTF16: 6, lengthUTF16: 5, kind: .link, linkURL: URL(string: "https://example.com/a?x=1"))
            ]
            reply = .init(messageID: try MessageID("message-0"))
            forward = .init(messageID: try MessageID("message-9"), senderUserID: try UserID("user-9"), sourceRevision: try .init(1))
        }

        func command() throws -> V2SendMessageCommand {
            try .init(
                roomID: roomID, senderUserID: senderID, clientMessageID: clientID,
                text: text, media: media, mentions: mentions, entities: entities,
                replyTo: reply, targetRule: targetRule, forwardedFrom: forward,
                limits: .init(maxUTF8Bytes: 128)
            )
        }
    }
}
