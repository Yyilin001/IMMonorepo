import Foundation
import IMV2Core

/// Explicit directions and lifecycle classes for every protobuf body. Adding a
/// body requires a policy decision because this switch has no default.
public enum V2TCPFramePolicy: Sendable, Equatable {
    case handshake, control, ephemeral, read, mutation, serverOnly
    public var permitsAutomaticReplay: Bool { false }

    public static func policy(for body: IMV2Envelope.OneOf_Body) -> Self {
        switch body {
        case .clientHello, .authenticate: return .handshake
        case .presencePublicationControl, .heartbeat, .syncAck, .snapshotAck, .authorPresentationEnd, .groupEventUnsubscribe, .unsubscribePresence, .unsubscribeTyping: return .control
        case .setTypingState: return .ephemeral
        case .syncPull, .syncSnapshot, .snapshotPagePull, .listRoomMembers, .userRoomDirectoryList, .roomSyncStateBatch, .accountRoomChangesStart, .roomLatestVisibleBatch, .groupEventPull, .groupEventSubscribe, .listReadReceiptReaders, .subscribePresence, .subscribeTyping, .getLiveActivityPreferences, .getGroupRolePolicyBaseline: return .read
        case .recordReadReceipt, .setConversationState, .setMessageFavorite: return .mutation
        case .presencePublicationControlled, .serverHello, .authenticated, .heartbeatAck, .messageAccepted, .membershipChanged, .messageWithdrawn, .messageReactionChanged, .messageEdited, .syncBatch, .resetRequired, .acknowledged, .snapshotManifest, .snapshotPage, .syncAvailable, .readReceiptRecorded, .roomMembersPage, .userRoomDirectoryPage, .roomSyncStateBatchResult, .accountRoomChangesReady, .accountRoomChanged, .accountRoomResyncRequired, .roomLatestVisibleBatchResult, .authorPresentationDelta, .authorPresentationEnded, .personalPreferenceReceipt, .groupEventPage, .groupEventSubscribed, .groupEventAvailable, .strangerMessagePermissionSet, .userAddPermissionSet, .readReceiptPreferencesSet, .readReceiptReadersPage, .liveActivityPreferencesSet, .presenceSubscribed, .typingStateChanged, .presenceChanged, .liveActivityPreferences, .conversationStateSet, .messageFavoriteChanged, .pinnedMessageChanged, .groupAnnouncementChanged, .groupRolePermissionsChanged, .groupMemberRoleChanged, .groupRolePolicyBaseline, .relationshipChanged, .userBlockChanged, .memberMuted, .memberRemovedByModerator, .error: return .serverOnly
        }
    }

    /// Only bounded, non-domain controls use reserved capacity. Domain recovery
    /// remains ordinary and carries the durable caller's retry classification.
    func context(service: String, scoped: V2NetworkWorkContext?) throws -> V2NetworkWorkContext {
        switch self {
        case .handshake, .serverOnly: throw V2TLSFrameConnectionError.unexpectedResponse
        case .control:
            return .init(service: service, priority: .critical, kind: .authentication)
        case .ephemeral:
            return .init(service: service, priority: .interactive, kind: .ordinary)
        case .read, .mutation:
            return .init(service: service, priority: scoped?.priority ?? .interactive,
                kind: .ordinary, orderingKey: scoped?.orderingKey, isRetry: scoped?.isRetry ?? false)
        }
    }
}
