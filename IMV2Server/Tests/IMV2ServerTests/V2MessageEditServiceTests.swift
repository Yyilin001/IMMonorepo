import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 message edit service")
struct V2MessageEditServiceTests {
    @Test("authenticated edit intent forwards its revision fence and durable IDs")
    func forwardsEdit() async throws {
        let store = EditStoreSpy()
        let service = V2MessageEditService(store: store, capacityProfile: try profile(), maximumTextUTF8Bytes: 64, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let request = V2AuthenticatedMessageEdit(roomID: try .init("00000000-0000-0000-0000-000000000911"), actorUserID: try .init("00000000-0000-0000-0000-000000000912"), operationID: try .init("00000000-0000-0000-0000-000000000913"), messageID: try .init("00000000-0000-0000-0000-000000000914"), expectedMessageRevision: 4, text: "replacement")

        let result = try await service.edit(request)

        guard case .edited(let edit) = result else { Issue.record("expected edit"); return }
        #expect(await store.command()?.expectedMessageRevision == 4)
        #expect(edit.text == "replacement")
        #expect(UUID(uuidString: edit.eventID.rawValue) != nil)
        #expect(UUID(uuidString: edit.fanoutPlanID.rawValue) != nil)
    }

    private func profile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 100, maxOutstandingFanoutUnits: 100, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 1))
    }
}

private actor EditStoreSpy: V2MessageEditStore {
    private var captured: V2EditMessageCommand?
    func edit(command: V2EditMessageCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2MessageEditOutcome {
        captured = command
        return .edited(try .init(roomID: command.roomID, messageID: command.messageID, text: command.text, messageRevision: command.expectedMessageRevision + 1, roomSequence: 2, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }
    func command() -> V2EditMessageCommand? { captured }
}
