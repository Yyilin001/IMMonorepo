// Test-only adapter; production requests use RoomRef clients.
@testable import IMV2ServerContracts
import Foundation
import IMV2Core

struct V2ConversationCapabilitiesTestService: V2GatewayConversationCapabilitiesHandling {
    private let store: any V2ConversationCapabilitiesStore
    private let now: @Sendable () -> Date
    init(store: any V2ConversationCapabilitiesStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws
        -> V2PersonalPreferenceReceipt
    { try await store.setConversationState(actorUserID: actorUserID, command: command, now: now()) }
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws
        -> V2PersonalPreferenceReceipt
    { try await store.setMessageFavorite(actorUserID: actorUserID, command: command, now: now()) }
}
