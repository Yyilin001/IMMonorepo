@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 live activity service")
struct V2LiveActivityServiceTests {
    @Test("observation authorization is delegated to the durable policy store")
    func forwardsObservationAuthorization() async throws {
        let store = LiveActivityStoreSpy()
        let service = V2LiveActivityService(store: store)
        let roomID: RoomID = try .init("00000000-0000-0000-0000-000000000091")
        let viewer: UserID = try .init("00000000-0000-0000-0000-000000000092")
        let subject: UserID = try .init("00000000-0000-0000-0000-000000000093")
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        try await service.authorizeObservation(roomID: roomID, viewerUserID: viewer, subjectUserID: subject, now: now)

        #expect(await store.observation() == .init(roomID: roomID, viewerUserID: viewer, subjectUserID: subject, now: now))
    }
}

private actor LiveActivityStoreSpy: V2LiveActivityStore {
    func presenceBatch(_ requests: [V2PresenceObservationRequest], now: Date) async throws -> [V2PresenceObservationRequest: V2PresenceObservationOutcome] {
        try await v2FixturePresenceBatch(store: self, requests, now: now)
    }

    struct Observation: Equatable, Sendable {
        let roomID: RoomID
        let viewerUserID: UserID
        let subjectUserID: UserID
        let now: Date
    }

    private var capturedObservation: Observation?

    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState {
        .init(roomID: roomID, targetUserID: viewerUserID, isOnline: false, expiresAt: now)
    }

    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: now)
    }

    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws {}
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) async throws {
        capturedObservation = .init(roomID: roomID, viewerUserID: viewerUserID, subjectUserID: subjectUserID, now: now)
    }
    func allowsOnlinePresence(userID: UserID) async throws -> Bool { true }
    func observation() -> Observation? { capturedObservation }
}
