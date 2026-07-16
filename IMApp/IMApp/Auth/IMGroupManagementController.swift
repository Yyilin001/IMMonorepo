import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func createIMGroupInvite(conversationID: String, expiresInSeconds: Int? = nil) async -> IMGroupInviteResponseBody? {
        await conversationRuntimeController.createGroupInvite(
            conversationID: conversationID,
            expiresInSeconds: expiresInSeconds
        )
    }

    func updateMyIMMemberNickname(conversationID: String, memberNickname: String?) async -> Bool {
        await conversationRuntimeController.updateMyMemberNickname(conversationID: conversationID, memberNickname: memberNickname)
    }

    func fetchIMGroupInvites(conversationID: String) async -> [IMGroupInviteResponseBody] {
        await conversationRuntimeController.fetchGroupInvites(conversationID: conversationID)
    }

    func revokeIMGroupInvite(conversationID: String, token: String) async -> Bool {
        await conversationRuntimeController.revokeGroupInvite(conversationID: conversationID, token: token)
    }

    func createIMConversation(kind: IMConversationKind, title: String, memberEmails: [String]) async -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmails = Array(
            Set(memberEmails.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            await imConversationStore.setStatusMessageAsync("至少需要填写一个成员邮箱。")
            return false
        }

        do {
            let receipt = try await sessionClient.createIMConversation(
                kind: kind,
                title: normalizedTitle.isEmpty ? nil : normalizedTitle,
                memberEmails: normalizedEmails
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            scheduleIMConversationCachePersist()
            await openIMConversation(receipt.conversationID.uuidString)
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func createDirectIMConversation(memberEmail: String) async -> String? {
        let normalizedEmail = memberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            await imConversationStore.setStatusMessageAsync("联系人邮箱不能为空。")
            return nil
        }

        do {
            let receipt = try await sessionClient.createIMConversation(
                kind: .direct,
                title: nil,
                memberEmails: [normalizedEmail]
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            scheduleIMConversationCachePersist()
            let conversationID = receipt.conversationID.uuidString
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
            await imConversationStore.setStatusMessageAsync("会话 ID 无效。")
            return false
        }

        guard !normalizedEmails.isEmpty else {
            await imConversationStore.setStatusMessageAsync("至少需要填写一个成员邮箱。")
            return false
        }

        do {
            _ = try await sessionClient.addIMConversationMembers(
                conversationID: trimmedConversationID,
                memberEmails: normalizedEmails
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
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
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool? = nil
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedConversationID.isEmpty else {
            await imConversationStore.setStatusMessageAsync("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.updateIMConversationMetadata(
                conversationID: trimmedConversationID,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                notice: notice?.trimmingCharacters(in: .whitespacesAndNewlines),
                avatarPreset: avatarPreset,
                muteAll: muteAll
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
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
            await imConversationStore.setStatusMessageAsync("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.updateIMConversationPreferences(
                conversationID: trimmedConversationID,
                isPinned: isPinned,
                isMuted: isMuted
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
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
            await imConversationStore.setStatusMessageAsync("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.removeIMConversationMember(
                conversationID: trimmedConversationID,
                memberUserID: memberUserID
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
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
            await imConversationStore.setStatusMessageAsync("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.updateIMConversationMemberRole(
                conversationID: trimmedConversationID,
                memberUserID: memberUserID,
                role: role
            )
            markServerOnline()
            scheduleIMConversationSummaryReadModelCorrection(force: true)
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
            await imConversationStore.setStatusMessageAsync("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.leaveIMConversation(conversationID: trimmedConversationID)
            markServerOnline()
            conversationRuntimeController.applyLatestConversationSummaryChanges(
                upserts: [],
                removedConversationIDs: [UUID(uuidString: trimmedConversationID)].compactMap { $0 }
            )
            await imConversationStore.removeConversationAsync(id: trimmedConversationID)
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }
}
