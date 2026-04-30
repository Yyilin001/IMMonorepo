import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func reconnectIMConnection() async {
        guard case .signedIn = phase else {
            return
        }

        await disconnectIMConnection()
        scheduleIMConnectionIfNeeded()
    }

    func reloadIMConversations(force: Bool = true) async {
        await conversationRuntimeController.reloadConversations(force: force)
    }

    func loadMoreIMConversationSummariesIfNeeded(anchorConversationID: String?) async {
        await conversationRuntimeController.loadMoreConversationSummariesIfNeeded(anchorConversationID: anchorConversationID)
    }

    func jumpToReferencedIMMessage(_ messageID: String, in conversationID: String) async {
        await conversationRuntimeController.jumpToReferencedMessage(messageID, in: conversationID)
    }

    func jumpToIMMessage(_ messageID: String, in conversationID: String) async {
        await conversationRuntimeController.jumpToReferencedMessage(messageID, in: conversationID)
    }

    func searchIMConversationMessages(
        in conversationID: String,
        query: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> IMConversationMessageSearchPageResponseBody? {
        await conversationRuntimeController.searchConversationMessages(
            in: conversationID,
            query: query,
            cursor: cursor,
            limit: limit
        )
    }

    func downloadIMMedia(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await conversationRuntimeController.downloadMedia(
            asset,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    func downloadIMMediaToFile(
        _ asset: IMMediaAsset,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> URL {
        try await conversationRuntimeController.downloadMediaToFile(
            asset,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    func startBackgroundIMMediaDownload(
        _ asset: IMMediaAsset,
        to destinationURL: URL
    ) async throws {
        try await conversationRuntimeController.startBackgroundMediaDownload(asset, to: destinationURL)
    }

    func cancelBackgroundIMMediaDownload(
        _ reference: IMMessageBackgroundTransferReference
    ) async {
        await conversationRuntimeController.cancelBackgroundMediaDownload(reference)
    }

    func openIMConversation(_ conversationID: String) async {
        guard currentUser != nil else {
            return
        }

        imConversationStore.openConversation(id: conversationID)
        scheduleIMConversationCachePersist()
        await conversationRuntimeController.loadConversationMembers(for: conversationID)
        await conversationRuntimeController.loadMessagesIfNeeded(for: conversationID)
        await conversationRuntimeController.syncConversationAfterOpen(conversationID)
    }

    func createIMConversation(kind: IMConversationKind, title: String, memberEmails: [String]) async -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmails = Array(
            Set(memberEmails.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            imConversationStore.setStatusMessage("至少需要填写一个成员邮箱。")
            return false
        }

        do {
            let conversation = try await sessionClient.createIMConversation(
                kind: kind,
                title: normalizedTitle.isEmpty ? nil : normalizedTitle,
                memberEmails: normalizedEmails
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            scheduleIMConversationCachePersist()
            await openIMConversation(conversation.id.uuidString)
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func createDirectIMConversation(memberEmail: String) async -> String? {
        let normalizedEmail = memberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            imConversationStore.setStatusMessage("联系人邮箱不能为空。")
            return nil
        }

        do {
            let conversation = try await sessionClient.createIMConversation(
                kind: .direct,
                title: nil,
                memberEmails: [normalizedEmail]
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            scheduleIMConversationCachePersist()
            let conversationID = conversation.id.uuidString
            await openIMConversation(conversationID)
            return conversationID
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    func addIMConversationMembers(
        to conversationID: String,
        memberEmails: [String]
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmails = Array(
            Set(memberEmails.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
        ).sorted()

        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        guard !normalizedEmails.isEmpty else {
            imConversationStore.setStatusMessage("至少需要填写一个成员邮箱。")
            return false
        }

        do {
            let conversation = try await sessionClient.addIMConversationMembers(
                conversationID: trimmedConversationID,
                memberEmails: normalizedEmails
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            await conversationRuntimeController.loadConversationMembers(for: trimmedConversationID)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            await handleIMDataRequestError(error)
            return false
        }
    }

    func renameIMConversation(
        _ conversationID: String,
        title: String
    ) async -> Bool {
        await updateIMConversationMetadata(
            conversationID,
            title: title,
            notice: nil,
            avatarPreset: nil
        )
    }

    func updateIMConversationMetadata(
        _ conversationID: String,
        title: String? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        do {
            let conversation = try await sessionClient.updateIMConversationMetadata(
                conversationID: trimmedConversationID,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                notice: notice?.trimmingCharacters(in: .whitespacesAndNewlines),
                avatarPreset: avatarPreset
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            scheduleIMConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func updateIMConversationPreferences(
        _ conversationID: String,
        isPinned: Bool? = nil,
        isMuted: Bool? = nil
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        do {
            let conversation = try await sessionClient.updateIMConversationPreferences(
                conversationID: trimmedConversationID,
                isPinned: isPinned,
                isMuted: isMuted
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            scheduleIMConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func removeIMConversationMember(
        memberUserID: UUID,
        from conversationID: String
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        do {
            let conversation = try await sessionClient.removeIMConversationMember(
                conversationID: trimmedConversationID,
                memberUserID: memberUserID
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            await conversationRuntimeController.loadConversationMembers(for: trimmedConversationID)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            await handleIMDataRequestError(error)
            return false
        }
    }

    func updateIMConversationMemberRole(
        memberUserID: UUID,
        role: IMConversationMemberRole,
        in conversationID: String
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        do {
            let conversation = try await sessionClient.updateIMConversationMemberRole(
                conversationID: trimmedConversationID,
                memberUserID: memberUserID,
                role: role
            )
            markServerOnline()
            conversationRuntimeController.applyConversationSummaryReadModel([conversation])
            await conversationRuntimeController.loadConversationMembers(for: trimmedConversationID)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            await handleIMDataRequestError(error)
            return false
        }
    }

    func leaveIMConversation(_ conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.leaveIMConversation(conversationID: trimmedConversationID)
            markServerOnline()
            conversationRuntimeController.applyLatestConversationSummaryChanges(
                upserts: [],
                removedConversationIDs: [UUID(uuidString: trimmedConversationID)].compactMap { $0 }
            )
            imConversationStore.removeConversation(id: trimmedConversationID)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func refreshIMConversationSummaryReadModelIfNeeded() async {
        await conversationRuntimeController.refreshConversationSummaryReadModelIfNeeded()
    }

    func loadOlderIMMessages() async {
        await conversationRuntimeController.loadOlderMessages()
    }

    func appDidBecomeActive() async {
        guard case .signedIn = phase else {
            return
        }

        conversationRuntimeController.appDidBecomeActive()
        await refreshIMConversationSummaryReadModelIfNeeded()
    }

    func appDidEnterBackground() async {
        await flushIMConversationCache()
        await flushContactStateCache()
    }

    func markIncomingContactRequestsSeen() {
        if let latestIncomingContactRequestAt {
            lastSeenIncomingContactRequestAt = latestIncomingContactRequestAt
        }

        recomputeIncomingContactRequestUnreadState()
        scheduleContactStateCachePersist()
    }

    func sendIMText(_ text: String, to conversationID: String) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.sendText(text, to: conversationID)
    }

    func sendIMReply(
        reference: IMReplyReference,
        text: String,
        to conversationID: String
    ) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.sendReply(reference: reference, text: text, to: conversationID)
    }

    func sendIMMedia(
        fileURL: URL,
        kind: IMMediaAssetKind,
        mimeType: String,
        filename: String? = nil,
        byteSize: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationMillis: Int? = nil,
        previewAssetID: String? = nil,
        to conversationID: String
    ) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.sendMedia(
            fileURL: fileURL,
            kind: kind,
            mimeType: mimeType,
            filename: filename,
            byteSize: byteSize,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID,
            to: conversationID
        )
    }

    func retryIMTextMessage(localMessageID: String, in conversationID: String) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.retryTextMessage(
            localMessageID: localMessageID,
            in: conversationID
        )
    }

    func cancelQueuedIMTextMessage(localMessageID: String, in conversationID: String) -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        let didCancel = imConversationStore.cancelQueuedOutgoingMessage(
            localMessageID: localMessageID,
            conversationID: conversationID
        )
        if didCancel {
            scheduleIMConversationCachePersist()
        }
        return didCancel
    }

    func recallIMMessage(messageID: String, in conversationID: String) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.recallMessage(messageID: messageID, in: conversationID)
    }

    func editIMMessage(messageID: String, text: String, in conversationID: String) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.editMessage(
            messageID: messageID,
            text: text,
            in: conversationID
        )
    }

    func toggleIMMessageReaction(messageID: String, emoji: String, in conversationID: String) async -> Bool {
        guard case .signedIn = phase else {
            return false
        }

        return await conversationRuntimeController.toggleMessageReaction(
            messageID: messageID,
            emoji: emoji,
            in: conversationID
        )
    }
}
