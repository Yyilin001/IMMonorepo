import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@Suite("V2 App conversation outbox sender")
struct V2OutboxConversationSenderTests {
    @Test("group mentions cross the App sender boundary into the durable outbox")
    func groupMentionsReachTheDurableOutboxAndTransport() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = OutboxSenderCommandStoreSpy()
        let transport = OutboxSenderMessageTransportSpy()
        let outbox = V2CommandOutboxEngine(
            store: store,
            transport: transport,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000821")! },
            now: { now }
        )
        let sender: any V2ConversationSending = V2OutboxConversationSender(outbox: outbox)
        let media = V2MediaReference(mediaID: try .init("00000000-0000-0000-0000-000000000822"))
        let mentions: [V2MentionTarget] = [
            .user(try .init("00000000-0000-0000-0000-000000000823")),
            .everyone
        ]

        let result = try await sender.send(
            text: "请关注",
            media: [media],
            mentions: mentions,
            in: "00000000-0000-0000-0000-000000000824"
        )

        #expect(result == .accepted)
        let command = try #require(await store.enqueuedCommand())
        #expect(command.text == "请关注")
        #expect(command.media == [media])
        #expect(command.mentions == mentions)
        #expect(await transport.receivedMentions() == [mentions])
    }
}

private actor OutboxSenderCommandStoreSpy: V2LocalCommandStore {
    private var command: V2PendingMessageCommand?

    func enqueue(_ command: V2PendingMessageCommand) {
        self.command = command
    }

    func nextReadyMessage(now _: Date) -> V2PendingMessageCommand? {
        command
    }

    func markMessageAccepted(clientMessageID _: ClientMessageID, messageID _: MessageID, roomSequence _: UInt64) {}

    func scheduleMessageRetry(clientMessageID _: ClientMessageID, nextAttemptAt _: Date) {}

    func rejectMessage(clientMessageID _: ClientMessageID, code _: String) {}

    func enqueuedCommand() -> V2PendingMessageCommand? {
        command
    }
}

private actor OutboxSenderMessageTransportSpy: V2ClientMessageTransport {
    private var mentionTargets: [[V2MentionTarget]] = []

    func sendMessage(
        roomID: RoomID,
        clientMessageID _: ClientMessageID,
        text _: String,
        media _: [V2MediaReference],
        mentions: [V2MentionTarget],
        entities _: [V2MessageEntity],
        replyTo _: V2MessageReplyReference?
    ) throws -> V2ClientMessageAcceptance {
        mentionTargets.append(mentions)
        return try .init(
            messageID: .init("00000000-0000-0000-0000-000000000825"),
            roomID: roomID,
            roomSequence: 1,
            createdAt: .distantPast
        )
    }

    func receivedMentions() -> [[V2MentionTarget]] {
        mentionTargets
    }
}
