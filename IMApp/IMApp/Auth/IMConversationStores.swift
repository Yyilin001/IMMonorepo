import Foundation
import IMClientKit
import Observation

@MainActor
protocol IMConversationPresentationProviding: AnyObject {
    var imConnectionStatus: AuthManager.IMConnectionStatus { get }

    func conversationIdentityPresentation(for conversationID: String) -> IMConversationIdentityPresentation?
    func conversationIdentityPresentation(for conversation: IMConversation) -> IMConversationIdentityPresentation
    func directPeerRelationshipPresentation(for conversationID: String) -> DirectPeerRelationshipPresentation?
    func directRelationshipNotice(for conversationID: String) -> DirectRelationshipNotice?
}

@MainActor
protocol IMConversationRuntimeProviding: AnyObject {
    var currentUser: AuthUser? { get }
    var blockedUserIDs: Set<UUID> { get }
    var isFlushingQueuedIMTextMessages: Bool { get }
    var imConversationStore: IMConversationStore { get }

    func reloadIMConversations(force: Bool, kind: IMConversationKind?) async
    func loadMoreIMConversationSummariesIfNeeded(anchorConversationID: String?, kind: IMConversationKind?) async
    func createIMConversation(kind: IMConversationKind, title: String, memberEmails: [String]) async -> Bool
    func addIMConversationMembers(to conversationID: String, memberEmails: [String]) async -> Bool
    func openIMConversation(_ conversationID: String) async
    func loadOlderIMMessages() async
    func jumpToReferencedIMMessage(_ messageID: String, in conversationID: String) async
    func jumpToIMMessage(_ messageID: String, in conversationID: String) async
    func markIMConversationReadUpToLatestLoadedSequence(for conversationID: String) async
    func cancelQueuedIMTextMessage(localMessageID: String, in conversationID: String) -> Bool
    func recallIMMessage(messageID: String, in conversationID: String) async -> Bool
    func retryIMTextMessage(localMessageID: String, in conversationID: String) async -> Bool
    func toggleIMMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool
    func favoriteIMMessage(_ messageID: String, in conversationID: String) async -> Bool
    func unfavoriteIMMessage(_ messageID: String, in conversationID: String) async -> Bool
    func deleteIMMessagesForSelf(_ messageIDs: [String], in conversationID: String) async -> Bool
    func forwardIMMessages(_ messageIDs: [String], from conversationID: String, to targetConversationIDs: [String]) async -> Bool
    func fetchIMFavorites(conversationID: UUID?, cursor: String?, limit: Int?) async -> IMFavoritePageResponseBody?
    func clearIMConversationForSelf(_ conversationID: String) async -> Bool
    func deleteIMConversationForSelf(_ conversationID: String) async -> Bool
    func updateIMConversationPreferences(_ conversationID: String, isPinned: Bool?, isMuted: Bool?) async -> Bool
    func sendIMText(_ text: String, to conversationID: String) async -> Bool
    func sendIMReply(reference: IMReplyReference, text: String, to conversationID: String) async -> Bool
    func sendIMMedia(
        fileURL: URL,
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String?,
        byteSize: Int64?,
        width: Int?,
        height: Int?,
        durationMillis: Int?,
        previewAssetID: String?,
        to conversationID: String
    ) async -> Bool
    func editIMMessage(messageID: String, text: String, in conversationID: String) async -> Bool
    func renameIMConversation(_ conversationID: String, title: String) async -> Bool
    func updateIMConversationMetadata(
        _ conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        muteAll: Bool?
    ) async -> Bool
    func updateIMConversationMemberRole(memberUserID: UUID, role: IMConversationMemberRole, in conversationID: String) async -> Bool
    func removeIMConversationMember(memberUserID: UUID, from conversationID: String) async -> Bool
    func loadIMConversationMembers(conversationID: String, query: String) async
    func loadMoreIMConversationMembers(conversationID: String) async
    func loadIMReceiptSummary(conversationID: String) async
    func searchIMConversationMessages(
        in conversationID: String,
        query: String,
        cursor: String?,
        limit: Int?
    ) async -> IMConversationMessageSearchPageResponseBody?
    func updateMyIMMemberNickname(conversationID: String, memberNickname: String?) async -> Bool
    func leaveIMConversation(_ conversationID: String) async -> Bool
    func fetchIMGroupInvites(conversationID: String) async -> [IMGroupInviteResponseBody]
    func createIMGroupInvite(conversationID: String, expiresInSeconds: Int?) async -> IMGroupInviteResponseBody?
    func revokeIMGroupInvite(conversationID: String, token: String) async -> Bool
    func blockUserResult(_ userID: UUID, reason: String?) async -> ContactOperationResult
    func unblockUserResult(_ userID: UUID) async -> ContactOperationResult
    func createReportResult(
        targetType: String,
        targetID: String,
        conversationID: UUID?,
        messageID: UUID?,
        reason: String,
        detail: String?
    ) async -> ContactOperationResult
    func sendDirectConversationFriendRequestResult(conversationID: String) async -> ContactOperationResult
    func acceptDirectConversationFriendRequestResult(conversationID: String, remark: String?) async -> ContactOperationResult
    func declineDirectConversationFriendRequestResult(conversationID: String) async -> ContactOperationResult
    func cancelDirectConversationFriendRequestResult(conversationID: String) async -> ContactOperationResult
    func setDirectRelationshipNotice(_ result: ContactOperationResult, conversationID: String)
    func persistIMConversationCacheSoon()
    func startBackgroundIMMediaDownload(_ asset: IMMediaAsset, to destinationURL: URL) async throws
    func cancelBackgroundIMMediaDownload(_ reference: IMMessageBackgroundTransferReference) async
}

extension AuthManager: IMConversationPresentationProviding, IMConversationRuntimeProviding {}

@MainActor
@Observable
final class IMConversationPresentationStore {
    @ObservationIgnored
    private weak var provider: (any IMConversationPresentationProviding)?

    init(provider: any IMConversationPresentationProviding) {
        self.provider = provider
    }

    var imConnectionStatus: AuthManager.IMConnectionStatus {
        provider?.imConnectionStatus ?? .disconnected
    }

    func conversationIdentityPresentation(for conversation: IMConversation) -> IMConversationIdentityPresentation {
        provider?.conversationIdentityPresentation(for: conversation)
            ?? IMConversationIdentityPresentation(
                title: conversation.title,
                detailSummary: "\(conversation.memberCount) 位成员",
                rowSecondaryLabel: nil
            )
    }

    func conversationIdentityPresentation(for conversationID: String) -> IMConversationIdentityPresentation? {
        provider?.conversationIdentityPresentation(for: conversationID)
    }

    func directPeerRelationshipPresentation(
        for conversationID: String
    ) -> DirectPeerRelationshipPresentation? {
        provider?.directPeerRelationshipPresentation(for: conversationID)
    }

    func directRelationshipNotice(for conversationID: String) -> DirectRelationshipNotice? {
        provider?.directRelationshipNotice(for: conversationID)
    }
}

@MainActor
@Observable
final class IMConversationRuntimeStore {
    @ObservationIgnored
    private weak var provider: (any IMConversationRuntimeProviding)?

    init(provider: any IMConversationRuntimeProviding) {
        self.provider = provider
    }

    func reloadConversations(force: Bool = true, kind: IMConversationKind? = nil) async {
        await provider?.reloadIMConversations(force: force, kind: kind)
    }

    func loadMoreConversationSummariesIfNeeded(
        anchorConversationID: String?,
        kind: IMConversationKind? = nil
    ) async {
        await provider?.loadMoreIMConversationSummariesIfNeeded(
            anchorConversationID: anchorConversationID,
            kind: kind
        )
    }

    func createConversation(kind: IMConversationKind, title: String, memberEmails: [String]) async -> Bool {
        await provider?.createIMConversation(kind: kind, title: title, memberEmails: memberEmails) ?? false
    }

    func addConversationMembers(to conversationID: String, memberEmails: [String]) async -> Bool {
        await provider?.addIMConversationMembers(to: conversationID, memberEmails: memberEmails) ?? false
    }

    var currentUserID: UUID? {
        provider?.currentUser?.id
    }

    var currentUserDisplayName: String {
        provider?.currentUser?.preferredDisplayName ?? "用户"
    }

    var blockedUserIDs: Set<UUID> {
        provider?.blockedUserIDs ?? []
    }

    var isFlushingQueuedTextMessages: Bool {
        provider?.isFlushingQueuedIMTextMessages ?? false
    }

    func openConversation(_ conversationID: String) async {
        await provider?.openIMConversation(conversationID)
    }

    func loadOlderMessages() async {
        await provider?.loadOlderIMMessages()
    }

    func jumpToReferencedMessage(_ messageID: String, in conversationID: String) async {
        await provider?.jumpToReferencedIMMessage(messageID, in: conversationID)
    }

    func jumpToMessage(_ messageID: String, in conversationID: String) async {
        await provider?.jumpToIMMessage(messageID, in: conversationID)
    }

    func markConversationRead(_ conversationID: String) async {
        await provider?.markIMConversationReadUpToLatestLoadedSequence(for: conversationID)
    }

    func markConversationUnread(_ conversationID: String) async {
        await provider?.imConversationStore.markConversationUnreadAsync(id: conversationID)
        provider?.persistIMConversationCacheSoon()
    }

    func cancelQueuedTextMessage(localMessageID: String, in conversationID: String) -> Bool {
        provider?.cancelQueuedIMTextMessage(localMessageID: localMessageID, in: conversationID) ?? false
    }

    func recallMessage(messageID: String, in conversationID: String) async -> Bool {
        await provider?.recallIMMessage(messageID: messageID, in: conversationID) ?? false
    }

    func retryTextMessage(localMessageID: String, in conversationID: String) async -> Bool {
        await provider?.retryIMTextMessage(localMessageID: localMessageID, in: conversationID) ?? false
    }

    func toggleMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool {
        await provider?.toggleIMMessageReaction(messageID: messageID, emoji: emoji, in: conversationID) ?? false
    }

    func favoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        await provider?.favoriteIMMessage(messageID, in: conversationID) ?? false
    }

    func unfavoriteMessage(messageID: String, in conversationID: String) async -> Bool {
        await provider?.unfavoriteIMMessage(messageID, in: conversationID) ?? false
    }

    func deleteMessagesForSelf(messageIDs: [String], in conversationID: String) async -> Bool {
        await provider?.deleteIMMessagesForSelf(messageIDs, in: conversationID) ?? false
    }

    func forwardMessages(messageIDs: [String], from conversationID: String, to targetConversationIDs: [String]) async -> Bool {
        await provider?.forwardIMMessages(messageIDs, from: conversationID, to: targetConversationIDs) ?? false
    }

    func fetchFavorites(
        conversationID: UUID? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMFavoritePageResponseBody? {
        await provider?.fetchIMFavorites(conversationID: conversationID, cursor: cursor, limit: limit)
    }

    func clearConversationForSelf(_ conversationID: String) async -> Bool {
        await provider?.clearIMConversationForSelf(conversationID) ?? false
    }

    func deleteConversationForSelf(_ conversationID: String) async -> Bool {
        await provider?.deleteIMConversationForSelf(conversationID) ?? false
    }

    func updateConversationPreferences(
        _ conversationID: String,
        isPinned: Bool? = nil,
        isMuted: Bool? = nil
    ) async -> Bool {
        await provider?.updateIMConversationPreferences(conversationID, isPinned: isPinned, isMuted: isMuted) ?? false
    }

    func sendText(_ text: String, to conversationID: String) async -> Bool {
        await provider?.sendIMText(text, to: conversationID) ?? false
    }

    func sendReply(reference: IMReplyReference, text: String, to conversationID: String) async -> Bool {
        await provider?.sendIMReply(reference: reference, text: text, to: conversationID) ?? false
    }

    func sendMedia(
        fileURL: URL,
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String? = nil,
        byteSize: Int64? = nil,
        to conversationID: String
    ) async -> Bool {
        await provider?.sendIMMedia(
            fileURL: fileURL,
            kind: kind,
            mimeType: mimeType,
            filename: filename,
            byteSize: byteSize,
            width: nil,
            height: nil,
            durationMillis: nil,
            previewAssetID: nil,
            to: conversationID
        ) ?? false
    }

    func editMessage(messageID: String, text: String, in conversationID: String) async -> Bool {
        await provider?.editIMMessage(messageID: messageID, text: text, in: conversationID) ?? false
    }

    func renameConversation(_ conversationID: String, title: String) async -> Bool {
        await provider?.renameIMConversation(conversationID, title: title) ?? false
    }

    func updateConversationMetadata(
        _ conversationID: String,
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?,
        muteAll: Bool? = nil
    ) async -> Bool {
        await provider?.updateIMConversationMetadata(
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
        await provider?.updateIMConversationMemberRole(
            memberUserID: memberUserID,
            role: role,
            in: conversationID
        ) ?? false
    }

    func removeConversationMember(memberUserID: UUID, from conversationID: String) async -> Bool {
        await provider?.removeIMConversationMember(memberUserID: memberUserID, from: conversationID) ?? false
    }

    func loadConversationMembers(_ conversationID: String, query: String = "") async {
        await provider?.loadIMConversationMembers(conversationID: conversationID, query: query)
    }

    func loadMoreConversationMembers(_ conversationID: String) async {
        await provider?.loadMoreIMConversationMembers(conversationID: conversationID)
    }

    func loadReceiptSummary(_ conversationID: String) async {
        await provider?.loadIMReceiptSummary(conversationID: conversationID)
    }

    func searchMessages(
        in conversationID: String,
        query: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMConversationMessageSearchPageResponseBody? {
        await provider?.searchIMConversationMessages(
            in: conversationID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }

    func updateMyMemberNickname(_ conversationID: String, memberNickname: String?) async -> Bool {
        await provider?.updateMyIMMemberNickname(conversationID: conversationID, memberNickname: memberNickname) ?? false
    }

    func leaveConversation(_ conversationID: String) async -> Bool {
        await provider?.leaveIMConversation(conversationID) ?? false
    }

    func fetchGroupInvites(conversationID: String) async -> [IMGroupInviteResponseBody] {
        await provider?.fetchIMGroupInvites(conversationID: conversationID) ?? []
    }

    func createGroupInvite(conversationID: String, expiresInSeconds: Int? = nil) async -> IMGroupInviteResponseBody? {
        await provider?.createIMGroupInvite(conversationID: conversationID, expiresInSeconds: expiresInSeconds)
    }

    func revokeGroupInvite(conversationID: String, token: String) async -> Bool {
        await provider?.revokeIMGroupInvite(conversationID: conversationID, token: token) ?? false
    }

    func blockUser(_ userID: UUID, reason: String? = nil) async -> ContactOperationResult {
        await provider?.blockUserResult(userID, reason: reason) ?? .failure("操作失败，请稍后重试。")
    }

    func unblockUser(_ userID: UUID) async -> ContactOperationResult {
        await provider?.unblockUserResult(userID) ?? .failure("操作失败，请稍后重试。")
    }

    func reportUser(_ userID: UUID, conversationID: String) async -> ContactOperationResult {
        await provider?.createReportResult(
            targetType: "user",
            targetID: userID.uuidString,
            conversationID: UUID(uuidString: conversationID),
            messageID: nil,
            reason: "inappropriate_behavior",
            detail: nil
        ) ?? .failure("操作失败，请稍后重试。")
    }

    func sendDirectConversationFriendRequest(conversationID: String) async -> ContactOperationResult {
        await provider?.sendDirectConversationFriendRequestResult(conversationID: conversationID)
            ?? .failure("操作失败，请稍后重试。")
    }

    func acceptDirectConversationFriendRequest(conversationID: String) async -> ContactOperationResult {
        await provider?.acceptDirectConversationFriendRequestResult(conversationID: conversationID, remark: nil)
            ?? .failure("操作失败，请稍后重试。")
    }

    func declineDirectConversationFriendRequest(conversationID: String) async -> ContactOperationResult {
        await provider?.declineDirectConversationFriendRequestResult(conversationID: conversationID)
            ?? .failure("操作失败，请稍后重试。")
    }

    func cancelDirectConversationFriendRequest(conversationID: String) async -> ContactOperationResult {
        await provider?.cancelDirectConversationFriendRequestResult(conversationID: conversationID)
            ?? .failure("操作失败，请稍后重试。")
    }

    func setDirectRelationshipNotice(_ result: ContactOperationResult, conversationID: String) {
        provider?.setDirectRelationshipNotice(result, conversationID: conversationID)
    }

    func setStatusMessage(_ message: String) {
        provider?.imConversationStore.setStatusMessage(message)
    }

    func persistConversationCacheSoon() {
        provider?.persistIMConversationCacheSoon()
    }

    func startBackgroundMediaDownload(_ asset: IMMediaAsset, to destinationURL: URL) async throws {
        try await provider?.startBackgroundIMMediaDownload(asset, to: destinationURL)
    }

    func cancelBackgroundMediaDownload(_ reference: IMMessageBackgroundTransferReference) async {
        await provider?.cancelBackgroundIMMediaDownload(reference)
    }
}
