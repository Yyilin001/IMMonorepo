import Combine
import Foundation
import IMClientKit

@MainActor
final class IMConversationPresentationStore: ObservableObject {
    private weak var authManager: AuthManager?
    private var cancellable: AnyCancellable?

    init(authManager: AuthManager) {
        self.authManager = authManager
        cancellable = authManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var imConnectionStatus: AuthManager.IMConnectionStatus {
        authManager?.imConnectionStatus ?? .disconnected
    }

    func conversationIdentityPresentation(for conversation: IMConversation) -> IMConversationIdentityPresentation {
        authManager?.conversationIdentityPresentation(for: conversation)
            ?? IMConversationIdentityPresentation(
                title: conversation.title,
                detailSummary: "\(conversation.memberCount) 位成员",
                rowSecondaryLabel: nil
            )
    }

    func directPeerRelationshipPresentation(
        for conversationID: String
    ) -> DirectPeerRelationshipPresentation? {
        authManager?.directPeerRelationshipPresentation(for: conversationID)
    }

    func directConversationRelationshipActionMessage(for conversationID: String) -> String? {
        authManager?.directConversationRelationshipActionMessage(for: conversationID)
    }
}

@MainActor
final class IMConversationRuntimeStore: ObservableObject {
    private weak var authManager: AuthManager?
    private var cancellable: AnyCancellable?

    init(authManager: AuthManager) {
        self.authManager = authManager
        cancellable = authManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func reloadConversations(force: Bool = true, kind: IMConversationKind? = nil) async {
        await authManager?.reloadIMConversations(force: force, kind: kind)
    }

    func loadMoreConversationSummariesIfNeeded(
        anchorConversationID: String?,
        kind: IMConversationKind? = nil
    ) async {
        await authManager?.loadMoreIMConversationSummariesIfNeeded(
            anchorConversationID: anchorConversationID,
            kind: kind
        )
    }

    var currentUserID: UUID? {
        authManager?.currentUser?.id
    }

    var currentUserDisplayName: String {
        authManager?.currentUser?.preferredDisplayName ?? "用户"
    }

    var blockedUserIDs: Set<UUID> {
        authManager?.blockedUserIDs ?? []
    }

    var isFlushingQueuedTextMessages: Bool {
        authManager?.isFlushingQueuedIMTextMessages ?? false
    }

    func openConversation(_ conversationID: String) async {
        await authManager?.openIMConversation(conversationID)
    }

    func loadOlderMessages() async {
        await authManager?.loadOlderIMMessages()
    }

    func jumpToReferencedMessage(_ messageID: String, in conversationID: String) async {
        await authManager?.jumpToReferencedIMMessage(messageID, in: conversationID)
    }

    func jumpToMessage(_ messageID: String, in conversationID: String) async {
        await authManager?.jumpToIMMessage(messageID, in: conversationID)
    }

    func cancelQueuedTextMessage(localMessageID: String, in conversationID: String) -> Bool {
        authManager?.cancelQueuedIMTextMessage(localMessageID: localMessageID, in: conversationID) ?? false
    }

    func recallMessage(messageID: String, in conversationID: String) async -> Bool {
        await authManager?.recallIMMessage(messageID: messageID, in: conversationID) ?? false
    }

    func retryTextMessage(localMessageID: String, in conversationID: String) async -> Bool {
        await authManager?.retryIMTextMessage(localMessageID: localMessageID, in: conversationID) ?? false
    }

    func toggleMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool {
        await authManager?.toggleIMMessageReaction(messageID: messageID, emoji: emoji, in: conversationID) ?? false
    }

    func favoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        await authManager?.favoriteIMMessage(messageID, in: conversationID) ?? false
    }

    func unfavoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        await authManager?.unfavoriteIMMessage(messageID, in: conversationID) ?? false
    }

    func deleteMessagesForSelf(messageIDs: [String], in conversationID: String) async -> Bool {
        await authManager?.deleteIMMessagesForSelf(messageIDs, in: conversationID) ?? false
    }

    func forwardMessages(messageIDs: [String], from conversationID: String, to targetConversationIDs: [String]) async -> Bool {
        await authManager?.forwardIMMessages(messageIDs, from: conversationID, to: targetConversationIDs) ?? false
    }

    func fetchFavorites(
        conversationID: UUID? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMFavoritePageResponseBody? {
        await authManager?.fetchIMFavorites(conversationID: conversationID, cursor: cursor, limit: limit)
    }

    func clearConversationForSelf(_ conversationID: String) async -> Bool {
        await authManager?.clearIMConversationForSelf(conversationID) ?? false
    }

    func deleteConversationForSelf(_ conversationID: String) async -> Bool {
        await authManager?.deleteIMConversationForSelf(conversationID) ?? false
    }

    func updateConversationPreferences(
        _ conversationID: String,
        isPinned: Bool? = nil,
        isMuted: Bool? = nil
    ) async -> Bool {
        await authManager?.updateIMConversationPreferences(conversationID, isPinned: isPinned, isMuted: isMuted) ?? false
    }

    func sendText(_ text: String, to conversationID: String) async -> Bool {
        await authManager?.sendIMText(text, to: conversationID) ?? false
    }

    func sendReply(reference: IMReplyReference, text: String, to conversationID: String) async -> Bool {
        await authManager?.sendIMReply(reference: reference, text: text, to: conversationID) ?? false
    }

    func sendMedia(
        fileURL: URL,
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String? = nil,
        byteSize: Int64? = nil,
        to conversationID: String
    ) async -> Bool {
        await authManager?.sendIMMedia(
            fileURL: fileURL,
            kind: kind,
            mimeType: mimeType,
            filename: filename,
            byteSize: byteSize,
            to: conversationID
        ) ?? false
    }

    func editMessage(messageID: String, text: String, in conversationID: String) async -> Bool {
        await authManager?.editIMMessage(messageID: messageID, text: text, in: conversationID) ?? false
    }

    func renameConversation(_ conversationID: String, title: String) async -> Bool {
        await authManager?.renameIMConversation(conversationID, title: title) ?? false
    }

    func updateConversationMetadata(
        _ conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        muteAll: Bool? = nil
    ) async -> Bool {
        await authManager?.updateIMConversationMetadata(
            conversationID,
            title: title,
            notice: notice,
            avatarPreset: avatarPreset,
            muteAll: muteAll
        ) ?? false
    }

    func updateConversationMemberRole(
        memberUserID: UUID,
        role: IMConversationMemberRole,
        in conversationID: String
    ) async -> Bool {
        await authManager?.updateIMConversationMemberRole(
            memberUserID: memberUserID,
            role: role,
            in: conversationID
        ) ?? false
    }

    func removeConversationMember(memberUserID: UUID, from conversationID: String) async -> Bool {
        await authManager?.removeIMConversationMember(memberUserID: memberUserID, from: conversationID) ?? false
    }

    func loadConversationMembers(_ conversationID: String, query: String = "") async {
        await authManager?.loadIMConversationMembers(conversationID: conversationID, query: query)
    }

    func loadMoreConversationMembers(_ conversationID: String) async {
        await authManager?.loadMoreIMConversationMembers(conversationID: conversationID)
    }

    func loadReceiptSummary(_ conversationID: String) async {
        await authManager?.loadIMReceiptSummary(conversationID: conversationID)
    }

    func updateMyMemberNickname(_ conversationID: String, memberNickname: String?) async -> Bool {
        await authManager?.updateMyIMMemberNickname(conversationID: conversationID, memberNickname: memberNickname) ?? false
    }

    func leaveConversation(_ conversationID: String) async -> Bool {
        await authManager?.leaveIMConversation(conversationID) ?? false
    }

    func fetchGroupInvites(conversationID: String) async -> [IMGroupInviteResponseBody] {
        await authManager?.fetchIMGroupInvites(conversationID: conversationID) ?? []
    }

    func createGroupInvite(conversationID: String, expiresInSeconds: Int? = nil) async -> IMGroupInviteResponseBody? {
        await authManager?.createIMGroupInvite(conversationID: conversationID, expiresInSeconds: expiresInSeconds)
    }

    func revokeGroupInvite(conversationID: String, token: String) async -> Bool {
        await authManager?.revokeIMGroupInvite(conversationID: conversationID, token: token) ?? false
    }

    func blockUser(_ userID: UUID, reason: String? = nil) async -> Bool {
        await authManager?.blockUser(userID, reason: reason) ?? false
    }

    func unblockUser(_ userID: UUID) async -> Bool {
        await authManager?.unblockUser(userID) ?? false
    }

    func reportUser(_ userID: UUID, conversationID: String) async -> Bool {
        await authManager?.createReport(
            targetType: "user",
            targetID: userID.uuidString,
            conversationID: UUID(uuidString: conversationID),
            reason: "inappropriate_behavior",
            detail: nil
        ) ?? false
    }

    func sendDirectConversationFriendRequest(conversationID: String) async {
        _ = await authManager?.sendDirectConversationFriendRequest(conversationID: conversationID)
    }

    func acceptDirectConversationFriendRequest(conversationID: String) async {
        _ = await authManager?.acceptDirectConversationFriendRequest(conversationID: conversationID)
    }

    func declineDirectConversationFriendRequest(conversationID: String) async {
        _ = await authManager?.declineDirectConversationFriendRequest(conversationID: conversationID)
    }

    func cancelDirectConversationFriendRequest(conversationID: String) async {
        _ = await authManager?.cancelDirectConversationFriendRequest(conversationID: conversationID)
    }

    func setStatusMessage(_ message: String) {
        authManager?.imConversationStore.setStatusMessage(message)
    }

    func persistConversationCacheSoon() {
        authManager?.persistIMConversationCacheSoon()
    }

    func startBackgroundMediaDownload(_ asset: IMMediaAsset, to destinationURL: URL) async throws {
        try await authManager?.startBackgroundIMMediaDownload(asset, to: destinationURL)
    }

    func cancelBackgroundMediaDownload(_ reference: IMMessageBackgroundTransferReference) async {
        await authManager?.cancelBackgroundIMMediaDownload(reference)
    }
}
