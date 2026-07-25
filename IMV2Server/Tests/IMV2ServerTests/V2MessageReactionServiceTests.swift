import Foundation
import IMV2Core
@testable import IMV2Server
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
        #expect(UUID(uuidString: change.fanoutPlanID.rawValue) != nil)
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1))
    }
}

private actor ReactionStoreSpy: V2MessageReactionStore {
    private var captured: V2ChangeMessageReactionCommand?
    func change(command: V2ChangeMessageReactionCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2MessageReactionOutcome {
        captured = command
        return .changed(.init(roomID: command.roomID, messageID: command.messageID, actorUserID: command.actorUserID, reaction: command.reaction, action: command.action, roomSequence: 1, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }
    func command() -> V2ChangeMessageReactionCommand? { captured }
}
