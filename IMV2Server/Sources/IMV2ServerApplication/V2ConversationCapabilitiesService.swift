import IMV2ServerContracts
import Foundation
import IMV2Core

public struct V2ConversationCapabilitiesService: Sendable {
    private let store: any V2ConversationCapabilitiesStore
    private let now: @Sendable () -> Date
    public init(store: any V2ConversationCapabilitiesStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }
    public func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand) async throws
        -> V2PersonalPreferenceReceipt
    { try await store.setConversationState(actorUserID: actorUserID, command: command, now: now()) }
    public func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand) async throws
        -> V2PersonalPreferenceReceipt
    { try await store.setMessageFavorite(actorUserID: actorUserID, command: command, now: now()) }
    public func recover(actorUserID: UserID, request: V2PersonalPreferenceRecoveryRequest) async throws
        -> V2PersonalPreferenceRecoveryResult
    { try await store.recover(actorUserID: actorUserID, request: request, now: now()) }
}
