@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 message reaction service")
struct V2MessageReactionServiceTests {
    @Test("authenticated reaction intent reaches the store with durable event and plan IDs")
    func forwardsReaction() async throws {
        let store = ReactionStoreSpy()
        let service = V2MessageReactionService(store: store, capacityProfile: try profile(), now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let request = V2AuthenticatedMessageReaction(roomID: try .init("00000000-0000-0000-0000-000000000901"), actorUserID: try .init("00000000-0000-0000-0000-000000000902"), operationID: try .init("00000000-0000-0000-0000-000000000903"), messageID: try .init("00000000-0000-0000-0000-000000000904"), reaction: "👍", action: .add)

        let result = try await service.change(request)

        guard case .changed(let change) = result else { Issue.record("expected reaction change"); return }
        #expect(await store.command()?.actorUserID == request.actorUserID)
        #expect(change.reaction == "👍")
        #expect(UUID(uuidString: change.eventID.rawValue) != nil)
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 1))
    }
}

private actor ReactionStoreSpy: V2MessageReactionStore {
    private var captured: V2ChangeMessageReactionCommand?
    func change(command: V2ChangeMessageReactionCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2MessageReactionOutcome {
        captured = command
        return .changed(try .init(roomID: command.roomID, messageID: command.messageID, actorUserID: command.actorUserID, reaction: command.reaction, action: command.action, roomSequence: 1, eventID: eventID, createdAt: now))
    }
    func command() -> V2ChangeMessageReactionCommand? { captured }
}
