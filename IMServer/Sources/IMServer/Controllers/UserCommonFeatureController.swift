import Fluent
import Vapor

extension UserController {
    func blocks(req: Request) async throws -> [UserBlockResponse] {
        let userID = try req.auth.require(User.self).requireID()
        let rows = try await UserBlock.query(on: req.db)
            .filter(\.$ownerUserID == userID)
            .sort(\.$createdAt, .descending)
            .all()
        return rows.map {
            UserBlockResponse(blockedUserID: $0.blockedUserID, reason: $0.reason, createdAt: $0.createdAt)
        }
    }

    func blockUser(req: Request) async throws -> UserBlockResponse {
        let userID = try req.auth.require(User.self).requireID()
        let blockedUserID = try routeUserID(from: req)
        guard userID != blockedUserID else {
            throw Abort(.badRequest, reason: "不能拉黑自己。")
        }
        guard try await User.find(blockedUserID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "用户不存在。")
        }
        let body = try? req.content.decode(UserBlockCreateRequest.self)
        let reason = body?.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let row = UserBlock(ownerUserID: userID, blockedUserID: blockedUserID, reason: reason)
        if let existing = try await UserBlock.find(row.id, on: req.db) {
            existing.reason = reason
            try await existing.update(on: req.db)
            return UserBlockResponse(blockedUserID: existing.blockedUserID, reason: existing.reason, createdAt: existing.createdAt)
        }
        try await row.create(on: req.db)
        return UserBlockResponse(blockedUserID: row.blockedUserID, reason: row.reason, createdAt: row.createdAt)
    }

    func unblockUser(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let blockedUserID = try routeUserID(from: req)
        if let row = try await UserBlock.find(UserBlock.recordID(ownerUserID: userID, blockedUserID: blockedUserID), on: req.db) {
            try await row.delete(on: req.db)
        }
        return .ok
    }

    func createReport(req: Request) async throws -> ReportResponse {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(ReportCreateRequest.self)
        let targetType = body.targetType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["user", "conversation", "message"].contains(targetType) else {
            throw Abort(.badRequest, reason: "举报对象类型无效。")
        }
        let targetID = body.targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetID.isEmpty, !reason.isEmpty else {
            throw Abort(.badRequest, reason: "举报对象和原因不能为空。")
        }
        let report = UserReport(
            reporterUserID: userID,
            targetType: targetType,
            targetID: targetID,
            conversationID: body.conversationID,
            messageID: body.messageID,
            reason: reason,
            detail: body.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            messageSnapshotJSON: try await reportMessageSnapshotJSON(
                conversationID: body.conversationID,
                messageID: body.messageID,
                on: req
            )
        )
        try await report.create(on: req.db)
        return ReportResponse(
            id: try report.requireID(),
            targetType: report.targetType,
            targetID: report.targetID,
            reporterUserID: report.reporterUserID,
            conversationID: report.conversationID,
            messageID: report.messageID,
            reason: report.reason,
            detail: report.detail,
            status: report.status,
            handledNote: report.handledNote,
            messageSnapshotJSON: report.messageSnapshotJSON,
            createdAt: report.createdAt
        )
    }

    private func reportMessageSnapshotJSON(conversationID: UUID?, messageID: UUID?, on req: Request) async throws -> String? {
        guard let conversationID, let messageID else {
            return nil
        }
        let db = try await req.application.conversationShardRouter.strongReadDatabase(forConversationID: conversationID)
        guard let message = try await ConversationMessage.find(messageID, on: db) else {
            return nil
        }
        let snapshot = ReportMessageSnapshot(
            conversationID: conversationID,
            messageID: messageID,
            senderUserID: message.$sender.id,
            serverSequence: message.serverSequence,
            content: try message.decodedContent(),
            derivedState: try message.decodedDerivedState(),
            createdAt: message.createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        return String(data: data, encoding: .utf8)
    }

    func registerPushDeviceToken(req: Request) async throws -> PushDeviceTokenResponse {
        let userID = try req.auth.require(User.self).requireID()
        let session = try req.auth.require(SessionContext.self)
        let body = try req.content.decode(PushDeviceTokenRegisterRequest.self)
        let platform = body.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = body.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard platform == "ios", !token.isEmpty else {
            throw Abort(.badRequest, reason: "当前只支持 iOS APNs token。")
        }
        let row = PushDeviceToken(ownerUserID: userID, sessionID: session.sessionID, platform: platform, token: token)
        if let existing = try await PushDeviceToken.find(row.id, on: req.db) {
            existing.sessionID = session.sessionID
            existing.isActive = true
            existing.updatedAt = Date()
            try await existing.update(on: req.db)
            return PushDeviceTokenResponse(
                id: existing.id ?? row.id ?? "",
                platform: existing.platform,
                token: existing.token,
                isActive: existing.isActive,
                updatedAt: existing.updatedAt
            )
        }
        try await row.create(on: req.db)
        return PushDeviceTokenResponse(
            id: row.id ?? "",
            platform: row.platform,
            token: row.token,
            isActive: row.isActive,
            updatedAt: row.updatedAt
        )
    }

    func deletePushDeviceToken(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let tokenID = req.parameters.get("tokenID") else {
            throw Abort(.badRequest, reason: "设备 token ID 无效。")
        }
        guard let row = try await PushDeviceToken.find(tokenID, on: req.db),
              row.ownerUserID == userID
        else {
            return .ok
        }
        row.isActive = false
        row.updatedAt = Date()
        try await row.update(on: req.db)
        return .ok
    }

    private func routeUserID(from req: Request) throws -> UUID {
        guard let rawUserID = req.parameters.get("userID"),
              let userID = UUID(uuidString: rawUserID)
        else {
            throw Abort(.badRequest, reason: "用户 ID 无效。")
        }
        return userID
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
