import Fluent
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Vapor

struct IMAPNSConfiguration: Sendable {
    let keyID: String
    let teamID: String
    let bundleID: String
    let privateKeyPath: String
    let environment: String

    var host: String {
        environment == "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com"
    }

    static func load() -> IMAPNSConfiguration? {
        guard let keyID = Environment.get("APNS_KEY_ID")?.nilIfBlank,
              let teamID = Environment.get("APNS_TEAM_ID")?.nilIfBlank,
              let bundleID = Environment.get("APNS_BUNDLE_ID")?.nilIfBlank,
              let privateKeyPath = Environment.get("APNS_PRIVATE_KEY_PATH")?.nilIfBlank
        else {
            return nil
        }

        return IMAPNSConfiguration(
            keyID: keyID,
            teamID: teamID,
            bundleID: bundleID,
            privateKeyPath: privateKeyPath,
            environment: Environment.get("APNS_ENV")?.nilIfBlank == "production" ? "production" : "sandbox"
        )
    }
}

struct IMAPNSPushService {
    let app: Application

    func sendOfflinePushIfNeeded(for envelope: ConversationEventEnvelope) async {
        guard envelope.eventType == .messageCreated,
              let configuration = IMAPNSConfiguration.load(),
              let messageID = envelope.payload.messageID
        else {
            return
        }

        do {
            let db = try await app.conversationShardRouter.strongReadDatabase(forConversationID: envelope.conversationID)
            guard let message = try await ConversationMessage.query(on: db)
                .with(\.$sender)
                .filter(\.$id == messageID)
                .first()
            else {
                return
            }

            try await sendMessagePush(
                configuration: configuration,
                envelope: envelope,
                message: message,
                content: try message.decodedContent()
            )
        } catch {
            app.logger.warning(
                "Failed to prepare APNs push",
                metadata: [
                    "conversation_id": .string(envelope.conversationID.uuidString),
                    "error": .string(String(describing: error))
                ]
            )
        }
    }

    private func sendMessagePush(
        configuration: IMAPNSConfiguration,
        envelope: ConversationEventEnvelope,
        message: ConversationMessage,
        content: IMMessageContent
    ) async throws {
        let senderUserID = message.$sender.id
        let candidateUserIDs = Array(Set(envelope.payload.recipientUserIDs)).filter { $0 != senderUserID }
        guard !candidateUserIDs.isEmpty else {
            return
        }

        let offlineUserIDs = try await offlineRecipientUserIDs(from: candidateUserIDs)
        guard !offlineUserIDs.isEmpty else {
            return
        }

        let unmutedUserIDs = try await unmutedRecipientUserIDs(
            offlineUserIDs,
            conversationID: envelope.conversationID
        )
        guard !unmutedUserIDs.isEmpty else {
            return
        }

        let tokens = try await PushDeviceToken.query(on: app.db)
            .filter(\.$ownerUserID ~~ unmutedUserIDs)
            .filter(\.$isActive == true)
            .all()
            .filter { $0.platform.lowercased() == "ios" }
        guard !tokens.isEmpty else {
            return
        }

        let authToken = try makeProviderJWT(configuration: configuration)
        let senderName = message.sender.displayName?.nilIfBlank ?? message.sender.email
        let conversationTitle = try await pushConversationTitle(
            conversationID: envelope.conversationID,
            fallback: senderName
        )
        let alertBody = pushPreview(for: content)
        let messageID = try message.requireID()

        for token in tokens {
            do {
                try await send(
                    token: token.token,
                    configuration: configuration,
                    authToken: authToken,
                    payload: [
                        "aps": [
                            "alert": [
                                "title": conversationTitle,
                                "subtitle": senderName,
                                "body": alertBody
                            ],
                            "sound": "default",
                            "thread-id": envelope.conversationID.uuidString
                        ],
                        "conversationID": envelope.conversationID.uuidString,
                        "messageID": messageID.uuidString,
                        "senderUserID": senderUserID.uuidString
                    ]
                )
            } catch let error as IMAPNSError where error.shouldDeactivateToken {
                try await deactivateToken(token)
                app.logger.info(
                    "Deactivated APNs device token",
                    metadata: [
                        "token_id": .string(token.id ?? ""),
                        "reason": .string(error.reason ?? String(describing: error.statusCode))
                    ]
                )
            } catch {
                app.logger.warning(
                    "APNs push failed",
                    metadata: [
                        "token_id": .string(token.id ?? ""),
                        "error": .string(String(describing: error))
                    ]
                )
            }
        }
    }

    private func offlineRecipientUserIDs(from userIDs: [UUID]) async throws -> [UUID] {
        var onlineUserIDs = Set<UUID>()
        for userID in userIDs {
            if await app.imConnectionRegistry.localConnectionCount(forUserID: userID) > 0 {
                onlineUserIDs.insert(userID)
            }
        }

        let remoteRoutes = try? await app.connectionRoutingService.backend.presenceStore.routeNodeIDs(forUserIDs: userIDs)
        onlineUserIDs.formUnion((remoteRoutes ?? [:]).keys)
        return userIDs.filter { !onlineUserIDs.contains($0) }
    }

    private func unmutedRecipientUserIDs(_ userIDs: [UUID], conversationID: UUID) async throws -> [UUID] {
        var result: [UUID] = []
        for userID in userIDs {
            let db = app.summaryShardRouter.database(forOwnerUserID: userID)
            let recordID = ConversationUserSummary.recordID(ownerUserID: userID, conversationID: conversationID)
            if let summary = try await ConversationUserSummary.find(recordID, on: db), summary.isMuted {
                continue
            }
            result.append(userID)
        }
        return result
    }

    private func pushConversationTitle(conversationID: UUID, fallback: String) async throws -> String {
        let db = try await app.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
        guard let conversation = try await Conversation.find(conversationID, on: db) else {
            return fallback
        }
        return conversation.title?.nilIfBlank ?? fallback
    }

    private func pushPreview(for content: IMMessageContent) -> String {
        switch content {
        case .richText, .reply:
            return "发来一条消息"
        case .image:
            return "发来一张图片"
        case .audio:
            return "发来一条语音"
        case .file:
            return "发来一个文件"
        }
    }

    private func send(
        token: String,
        configuration: IMAPNSConfiguration,
        authToken: String,
        payload: [String: Any]
    ) async throws {
        guard let url = URL(string: "\(configuration.host)/3/device/\(token)") else {
            throw Abort(.internalServerError, reason: "APNs endpoint is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(authToken)", forHTTPHeaderField: "authorization")
        request.setValue(configuration.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IMAPNSError(statusCode: -1, reason: "invalid_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(IMAPNSFailureResponse.self, from: data).reason) ?? String(data: data, encoding: .utf8)
            throw IMAPNSError(statusCode: http.statusCode, reason: reason)
        }
    }

    private func deactivateToken(_ token: PushDeviceToken) async throws {
        token.isActive = false
        token.updatedAt = Date()
        try await token.update(on: app.db)
    }

    private func makeProviderJWT(configuration: IMAPNSConfiguration) throws -> String {
        let header = try base64URLEncodedJSON([
            "alg": "ES256",
            "kid": configuration.keyID
        ])
        let claims = try base64URLEncodedJSON([
            "iss": configuration.teamID,
            "iat": Int(Date().timeIntervalSince1970)
        ])
        let signingInput = "\(header).\(claims)"
        let pem = try String(contentsOfFile: configuration.privateKeyPath, encoding: .utf8)
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URLEncode(signature.rawRepresentation))"
    }

    private func base64URLEncodedJSON(_ value: [String: Any]) throws -> String {
        try base64URLEncode(JSONSerialization.data(withJSONObject: value, options: []))
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct IMAPNSFailureResponse: Decodable {
    let reason: String?
}

private struct IMAPNSError: Error {
    let statusCode: Int
    let reason: String?

    var shouldDeactivateToken: Bool {
        statusCode == 410
            || reason == "BadDeviceToken"
            || reason == "Unregistered"
            || reason == "DeviceTokenNotForTopic"
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
