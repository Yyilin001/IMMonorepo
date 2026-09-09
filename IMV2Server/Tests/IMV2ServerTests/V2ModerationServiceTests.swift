import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 moderation service")
struct V2ModerationServiceTests {
    @Test("authenticated fields and immutable audit-safe action reach the store")
    func forwardsAuthenticatedModeration() async throws {
        let store = RecordingModerationStore()
        let profile = try testModerationProfile()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let identifiers = TestIdentifierSequence(["00000000-0000-0000-0000-000000000855", "00000000-0000-0000-0000-000000000856"])
        let ids = V2ModerationIDFactory(makeUUID: { UUID(uuidString: identifiers.next())! })
        let service = V2ModerationService(store: store, capacityProfile: profile, identifiers: ids, now: { now })
        let request = V2AuthenticatedModeration(
            roomID: try .init("00000000-0000-0000-0000-000000000851"),
            actorUserID: try .init("00000000-0000-0000-0000-000000000852"),
            operationID: try .init("00000000-0000-0000-0000-000000000853"),
            action: .muteMember,
            targetUserID: try .init("00000000-0000-0000-0000-000000000854"),
            muteUntil: now.addingTimeInterval(300),
            reasonCode: try .init("abuse_spam")
        )

        guard case .applied(let result) = try await service.apply(request) else { Issue.record("expected applied"); return }
        let received = try #require(await store.command())
        #expect(received.actorUserID == request.actorUserID)
        #expect(received.action == .muteMember)
        #expect(received.targetUserID == request.targetUserID)
        #expect(received.reasonCode == request.reasonCode)
        #expect(result.eventID.rawValue == "00000000-0000-0000-0000-000000000855")
        #expect(result.fanoutPlanID.rawValue == "00000000-0000-0000-0000-000000000856")
    }

    @Test("invalid command shapes fail before the persistence boundary")
    func rejectsInvalidShapeBeforeStore() async throws {
        let store = RecordingModerationStore()
        let profile = try testModerationProfile()
        let service = V2ModerationService(store: store, capacityProfile: profile)
        let request = V2AuthenticatedModeration(roomID: try .init("00000000-0000-0000-0000-000000000861"), actorUserID: try .init("00000000-0000-0000-0000-000000000862"), operationID: try .init("00000000-0000-0000-0000-000000000863"), action: .freezeRoom, targetUserID: try .init("00000000-0000-0000-0000-000000000864"), reasonCode: try .init("abuse_spam"))

        await #expect(throws: V2ModerationValidationError.invalidActionShape) { try await service.apply(request) }
        #expect(await store.command() == nil)
    }
}

private actor RecordingModerationStore: V2ModerationStore {
    private var received: V2ModerationCommand?

    func command() -> V2ModerationCommand? { received }

    func apply(command: V2ModerationCommand, capacityProfile _: V2CapacityProfile, eventID: EventID, planID: FanoutPlanID, now: Date) throws -> V2ModerationOutcome {
        received = command
        return .applied(try .init(roomID: command.roomID, operationID: command.operationID, action: command.action, targetUserID: command.targetUserID, messageID: command.messageID, muteUntil: command.muteUntil, roomSequence: 1, eventID: eventID, fanoutPlanID: planID, createdAt: now))
    }
}

private final class TestIdentifierSequence: @unchecked Sendable {
    private var identifiers: [String]
    private let lock = NSLock()
    init(_ identifiers: [String]) { self.identifiers = identifiers }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return identifiers.removeFirst()
    }
}

private func testModerationProfile() throws -> V2CapacityProfile {
    try .init(id: "standard", limits: .init(
        maxEligibleMembers: 16,
        maxCommandsPerWindow: 32,
        maxFanoutUnitsPerWindow: 32,
        maxOutstandingFanoutUnits: 64,
        maxOutstandingPlans: 16,
        maxEnumerationPageSize: 16,
        maxPlannerConcurrency: 1,
        maxDeliveryConcurrency: 1,
        retryAfterSeconds: 3
    ))
}
