import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2OutboxCancelledCapabilityTests {
    @Test("cancelled conversation state and favorite actions do not enqueue or send", arguments: [false, true])
    func cancelledCapability(favorite: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-app-cancelled-capability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()), userID: .init("cancelled-user"))
        do {
            let now = Date(timeIntervalSince1970: 1_000)
            let service = V2PersonalPreferenceService(accountID: try .init("cancelled-user"), store: store, transport: UnexpectedCapabilityTransport(), recovery: UnexpectedRecovery())
            let state = V2OutboxConversationStateChanger(service: service)
            let favorites = V2OutboxMessageFavoriter(service: service)
            let room = RoomID(uuid: UUID())
            let message = MessageID(uuid: UUID())
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if favorite {
                    return try await favorites.setFavorite(roomID: room.rawValue, messageID: message.rawValue, isFavorited: true)
                }
                return try await state.setState(roomID: room.rawValue, isPinned: true, isArchived: true, muteUntil: nil)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.preparePersonalPreferences(accountID: .init("cancelled-user"), now: now) == 0)
            #expect(try await store.dueOperationWork(now: now).isEmpty)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }
}

private struct UnexpectedCapabilityTransport: V2ClientConversationCapabilitiesTransport {
    func setConversationState(command: V2ConversationStateCommand) async throws -> V2PersonalPreferenceReceipt {
        Issue.record("cancelled conversation state must not reach transport")
        throw CancellationError()
    }
    func setMessageFavorite(command: V2MessageFavoriteCommand) async throws -> V2PersonalPreferenceReceipt {
        Issue.record("cancelled favorite must not reach transport")
        throw CancellationError()
    }
}

private struct UnexpectedRecovery: V2PersonalPreferenceRecovering {
    func recover(_ request: V2PersonalPreferenceRecoveryRequest) async throws -> V2PersonalPreferenceRecoveryResult {
        Issue.record("cancelled action must not recover")
        throw CancellationError()
    }
}
