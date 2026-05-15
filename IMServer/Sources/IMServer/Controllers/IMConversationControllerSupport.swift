import Vapor

extension IMConversationController {
    func conversationID(from req: Request) throws -> UUID {
        guard
            let rawConversationID = req.parameters.get("conversationID"),
            let conversationID = UUID(uuidString: rawConversationID)
        else {
            throw Abort(.badRequest, reason: "会话 ID 无效。")
        }

        return conversationID
    }

    func memberUserID(from req: Request) throws -> UUID {
        guard
            let rawMemberUserID = req.parameters.get("memberUserID"),
            let memberUserID = UUID(uuidString: rawMemberUserID)
        else {
            throw Abort(.badRequest, reason: "成员 ID 无效。")
        }

        return memberUserID
    }
}
