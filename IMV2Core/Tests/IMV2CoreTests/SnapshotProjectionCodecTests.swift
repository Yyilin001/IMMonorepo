import Foundation
import IMV2Core
import Testing

@Suite("V2 snapshot projection codec")
struct SnapshotProjectionCodecTests {
    @Test("deterministic snapshot bytes round-trip canonical message, social, and moderation projections")
    func roundTrip() throws {
        let message = try V2SnapshotMessageProjection(
            sourceEventID: .init("00000000-0000-0000-0000-000000000701"),
            messageID: .init("00000000-0000-0000-0000-000000000702"),
            roomID: .init("00000000-0000-0000-0000-000000000703"),
            roomSequence: 9,
            messageRevision: 2,
            senderUserID: .init("00000000-0000-0000-0000-000000000704"),
            text: "snapshot message",
            media: [.init(mediaID: .init("00000000-0000-0000-0000-000000000730"))],
            mediaPresentations: [try .init(mediaID: .init("00000000-0000-0000-0000-000000000730"), kind: .image, contentType: "image/jpeg", byteCount: 1_024)],
            mentions: [.user(try .init("00000000-0000-0000-0000-000000000709")), .everyone],
            forwardedFrom: try .init(messageID: .init("00000000-0000-0000-0000-000000000731"), senderUserID: .init("00000000-0000-0000-0000-000000000732")),
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            isWithdrawn: true,
            reactions: [try .init(actorUserID: .init("00000000-0000-0000-0000-000000000705"), reaction: "👍")]
        )

        let page = try V2SnapshotProjectionPage(
            messages: [message],
            relationships: [try .init(
                targetUserID: .init("00000000-0000-0000-0000-000000000706"),
                state: .pending,
                requestedByUserID: .init("00000000-0000-0000-0000-000000000707"),
                updatedAt: Date(timeIntervalSince1970: 1_750_000_001)
            )],
            userBlocks: [.init(
                targetUserID: .init("00000000-0000-0000-0000-000000000708"),
                isBlocked: true,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_002)
            )],
            strangerMessagePreference: .init(
                allowsStrangerMessages: false,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_003)
            ),
            moderationActions: [try .init(
                sourceEventID: .init("00000000-0000-0000-0000-000000000710"),
                roomID: .init("00000000-0000-0000-0000-000000000711"),
                roomSequence: 10,
                actorUserID: .init("00000000-0000-0000-0000-000000000712"),
                targetUserID: .init("00000000-0000-0000-0000-000000000713"),
                muteUntil: Date(timeIntervalSince1970: 1_750_000_100),
                createdAt: Date(timeIntervalSince1970: 1_750_000_004)
            )],
            roomControls: [try .init(
                sourceEventID: .init("00000000-0000-0000-0000-000000000714"),
                roomID: .init("00000000-0000-0000-0000-000000000715"),
                roomSequence: 11,
                actorUserID: .init("00000000-0000-0000-0000-000000000716"),
                isFrozen: true,
                createdAt: Date(timeIntervalSince1970: 1_750_000_005)
            )],
            roomProfiles: [try .init(
                sourceEventID: .init("00000000-0000-0000-0000-000000000717"),
                roomID: .init("00000000-0000-0000-0000-000000000718"),
                title: "群聊快照",
                ownerUserID: .init("00000000-0000-0000-0000-000000000719"),
                membershipRevision: 1,
                createdAt: Date(timeIntervalSince1970: 1_750_000_006)
            )],
            directRoomProfiles: [try .init(
                sourceEventID: .init("00000000-0000-0000-0000-000000000720"),
                roomID: .init("00000000-0000-0000-0000-000000000721"),
                publicIdentity: .init(
                    userID: .init("00000000-0000-0000-0000-000000000722"),
                    handle: .init("direct_user"),
                    displayName: "私聊对象"
                ),
                revision: 3,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_007)
            )],
            userAddPreference: .init(
                allowsBeingAdded: false,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_008)
            ),
            conversationStates: [try .init(
                roomID: .init("00000000-0000-0000-0000-000000000703"),
                isPinned: true,
                isArchived: false,
                muteUntil: Date(timeIntervalSince1970: 1_750_003_600),
                updatedAt: Date(timeIntervalSince1970: 1_750_000_009)
            )],
            messageFavorites: [try .init(
                roomID: .init("00000000-0000-0000-0000-000000000703"),
                messageID: .init("00000000-0000-0000-0000-000000000702"),
                isFavorited: true,
                updatedAt: Date(timeIntervalSince1970: 1_750_000_010)
            )]
        )
        let first = try V2SnapshotProjectionCodec.encode(page)
        let second = try V2SnapshotProjectionCodec.encode(page)
        #expect(first == second)
        #expect(try V2SnapshotProjectionCodec.decode(first) == [message])
        #expect(try V2SnapshotProjectionCodec.decodePage(first) == page)
    }

    @Test("snapshot pages reject malformed state rather than producing a partial reset")
    func rejectsMalformedPage() {
        #expect(throws: V2SnapshotProjectionError.invalidPage) {
            try V2SnapshotProjectionCodec.decode(Data("{}".utf8))
        }
    }
}
