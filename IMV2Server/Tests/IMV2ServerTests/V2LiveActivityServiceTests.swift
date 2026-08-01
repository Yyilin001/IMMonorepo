import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 live activity service")
struct V2LiveActivityServiceTests {
    @Test("preference writes preserve actor-scoped idempotency commands")
    func forwardsPreferenceCommand() async throws {
        let store = LiveActivityStoreSpy()
        let service = V2LiveActivityService(store: store)
        let command = try V2SetLiveActivityPreferencesCommand(
            actorUserID: .init("00000000-0000-0000-0000-000000000081"),
            operationID: .init("00000000-0000-0000-0000-000000000082"),
            allowsOnlinePresence: false,
            allowsTypingIndicators: true
        )
        let result = try await service.setPreferences(command, now: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(await store.command() == command)
        guard case .updated(let preference) = result else { Issue.record("expected updated preference"); return }
        #expect(!preference.allowsOnlinePresence)
        #expect(preference.allowsTypingIndicators)
    }
}

private actor LiveActivityStoreSpy: V2LiveActivityStore {
    private var captured: V2SetLiveActivityPreferencesCommand?

    func setPreferences(command: V2SetLiveActivityPreferencesCommand, now: Date) async throws -> V2SetLiveActivityPreferencesOutcome {
        captured = command
        return .updated(.init(
            allowsOnlinePresence: command.allowsOnlinePresence,
            allowsTypingIndicators: command.allowsTypingIndicators,
            updatedAt: now
        ))
    }

    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) async throws -> V2PresenceState {
        .init(roomID: roomID, targetUserID: viewerUserID, isOnline: false, expiresAt: now)
    }

    func preferences(userID: UserID, now: Date) async throws -> V2LiveActivityPreferences {
        .init(allowsOnlinePresence: true, allowsTypingIndicators: true, updatedAt: now)
    }

    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) async throws {}
    func allowsOnlinePresence(userID: UserID) async throws -> Bool { true }
    func command() -> V2SetLiveActivityPreferencesCommand? { captured }
}
