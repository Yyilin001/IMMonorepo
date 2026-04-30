import Vapor

struct IMOpsCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "relay-conversation-outbox", help: "Relay pending conversation outbox events to the configured event stream.")
        var relayConversationOutbox: Bool

        @Flag(name: "replay-conversation-dead-letter-events", help: "Replay pending conversation dead-letter events back to the primary Kafka topic.")
        var replayConversationDeadLetterEvents: Bool

        @Option(name: "limit", short: "l", help: "Maximum number of conversation outbox events to relay.")
        var limit: Int?
    }

    let help = "Runs IM maintenance operations without starting HTTP or TCP runtimes."

    func run(using context: CommandContext, signature: Signature) async throws {
        if signature.relayConversationOutbox {
            let relayedCount = try await ConversationOutboxRelay(app: context.application)
                .relayPendingEvents(limit: max(1, signature.limit ?? 200))
            context.console.print("Relayed \(relayedCount) conversation outbox events.")
            return
        }

        if signature.replayConversationDeadLetterEvents {
            let replayedCount = try await ConversationReplayService(app: context.application)
                .replayPendingEvents(limit: max(1, signature.limit ?? 200))
            context.console.print("Replayed \(replayedCount) conversation dead-letter events.")
            return
        }

        context.console.print("IM ops role initialized.")
    }
}
