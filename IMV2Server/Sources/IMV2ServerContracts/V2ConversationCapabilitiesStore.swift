import Foundation
import IMV2Core

public enum V2ConversationCapabilitiesStoreError: Error, Equatable, Sendable {
    case roomNotFound, messageNotFound, actorNotMember, invalidTimestamp, corruptPersistenceState,
        operationPayloadMismatch
}
public protocol V2ConversationCapabilitiesStore: Sendable {
    func setConversationState(actorUserID: UserID, command: V2ConversationStateCommand, now: Date) async throws
        -> V2PersonalPreferenceReceipt
    func setMessageFavorite(actorUserID: UserID, command: V2MessageFavoriteCommand, now: Date) async throws
        -> V2PersonalPreferenceReceipt
    func recover(actorUserID: UserID, request: V2PersonalPreferenceRecoveryRequest, now: Date) async throws
        -> V2PersonalPreferenceRecoveryResult
}
