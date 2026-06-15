import Foundation
import IMClientKit

extension ConversationRuntimeController {
    func createGroupInvite(conversationID: String, expiresInSeconds: Int? = nil) async -> IMGroupInviteResponseBody? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return nil
        }

        do {
            let invite = try await sessionClient.createIMGroupInvite(
                conversationID: trimmedConversationID,
                expiresInSeconds: expiresInSeconds
            )
            markServerOnline()
            return invite
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    func updateMyMemberNickname(conversationID: String, memberNickname: String?) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        do {
            let conversation = try await sessionClient.updateIMMyMemberProfile(
                conversationID: trimmedConversationID,
                memberNickname: memberNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            markServerOnline()
            await applyConversationSummaryReadModelAsync([conversation])
            await loadConversationMembers(for: trimmedConversationID)
            scheduleConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func fetchGroupInvites(conversationID: String) async -> [IMGroupInviteResponseBody] {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return []
        }

        do {
            let invites = try await sessionClient.fetchIMGroupInvites(conversationID: trimmedConversationID)
            markServerOnline()
            return invites
        } catch {
            await handleIMDataRequestError(error)
            return []
        }
    }

    func revokeGroupInvite(conversationID: String, token: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedToken.isEmpty else {
            return false
        }

        do {
            _ = try await sessionClient.revokeIMGroupInvite(conversationID: trimmedConversationID, token: trimmedToken)
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }
}
