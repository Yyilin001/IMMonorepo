import NIOHTTP1
import Vapor

enum IMConversationCommandRoute: CaseIterable, Sendable {
    case createConversation
    case addMembers
    case updateMyMemberProfile
    case removeMember
    case updateMemberRole
    case updateTitle
    case updatePreferences
    case updateMetadata
    case forwardMessages
    case deleteMessagesForSelf
    case favoriteMessage
    case unfavoriteMessage
    case editMessage
    case toggleReaction
    case recallMessage
    case startAIMessageStream
    case cancelMessageStream
    case markRead
    case clearConversationForSelf
    case deleteConversationForSelf
    case createInvite
    case listInvites
    case revokeInvite
    case joinInvite
    case leaveConversation

    var method: HTTPMethod {
        switch self {
        case .updateMyMemberProfile,
             .updatePreferences,
             .updateMetadata:
            return .PATCH
        case .unfavoriteMessage,
             .deleteConversationForSelf,
             .revokeInvite:
            return .DELETE
        case .listInvites:
            return .GET
        default:
            return .POST
        }
    }

    var path: [PathComponent] {
        switch self {
        case .createConversation:
            return ["conversations"]
        case .addMembers:
            return ["conversations", ":conversationID", "members"]
        case .updateMyMemberProfile:
            return ["conversations", ":conversationID", "members", "me"]
        case .removeMember:
            return ["conversations", ":conversationID", "members", ":memberUserID", "remove"]
        case .updateMemberRole:
            return ["conversations", ":conversationID", "members", ":memberUserID", "role"]
        case .updateTitle:
            return ["conversations", ":conversationID", "title"]
        case .updatePreferences:
            return ["conversations", ":conversationID", "preferences"]
        case .updateMetadata:
            return ["conversations", ":conversationID", "metadata"]
        case .forwardMessages:
            return ["conversations", ":conversationID", "messages", "forward"]
        case .deleteMessagesForSelf:
            return ["conversations", ":conversationID", "messages", "delete"]
        case .favoriteMessage:
            return ["conversations", ":conversationID", "messages", ":messageID", "favorite"]
        case .unfavoriteMessage:
            return ["conversations", ":conversationID", "messages", ":messageID", "favorite"]
        case .editMessage:
            return ["conversations", ":conversationID", "messages", ":messageID", "edit"]
        case .toggleReaction:
            return ["conversations", ":conversationID", "messages", ":messageID", "reactions"]
        case .recallMessage:
            return ["conversations", ":conversationID", "messages", ":messageID", "recall"]
        case .startAIMessageStream:
            return ["conversations", ":conversationID", "ai", "messages"]
        case .cancelMessageStream:
            return ["conversations", ":conversationID", "messages", ":messageID", "stream", "cancel"]
        case .markRead:
            return ["conversations", ":conversationID", "read"]
        case .clearConversationForSelf:
            return ["conversations", ":conversationID", "clear"]
        case .deleteConversationForSelf:
            return ["conversations", ":conversationID"]
        case .createInvite:
            return ["conversations", ":conversationID", "invites"]
        case .listInvites:
            return ["conversations", ":conversationID", "invites"]
        case .revokeInvite:
            return ["conversations", ":conversationID", "invites", ":token"]
        case .joinInvite:
            return ["invites", ":token", "join"]
        case .leaveConversation:
            return ["conversations", ":conversationID", "leave"]
        }
    }

    static func registerProxyRoutes(
        on routes: any RoutesBuilder,
        use handler: @Sendable @escaping (Request) async throws -> Response
    ) {
        for route in allCases {
            routes.on(route.method, route.path, use: handler)
        }
    }

    static func registerControllerRoutes(
        on routes: any RoutesBuilder,
        controller: IMConversationController
    ) {
        for route in allCases {
            switch route {
            case .createConversation:
                routes.on(route.method, route.path, use: controller.createConversation)
            case .addMembers:
                routes.on(route.method, route.path, use: controller.addMembers)
            case .updateMyMemberProfile:
                routes.on(route.method, route.path, use: controller.updateMyMemberProfile)
            case .removeMember:
                routes.on(route.method, route.path, use: controller.removeMember)
            case .updateMemberRole:
                routes.on(route.method, route.path, use: controller.updateMemberRole)
            case .updateTitle:
                routes.on(route.method, route.path, use: controller.updateTitle)
            case .updatePreferences:
                routes.on(route.method, route.path, use: controller.updatePreferences)
            case .updateMetadata:
                routes.on(route.method, route.path, use: controller.updateMetadata)
            case .forwardMessages:
                routes.on(route.method, route.path, use: controller.forwardMessages)
            case .deleteMessagesForSelf:
                routes.on(route.method, route.path, use: controller.deleteMessagesForSelf)
            case .favoriteMessage:
                routes.on(route.method, route.path, use: controller.favoriteMessage)
            case .unfavoriteMessage:
                routes.on(route.method, route.path, use: controller.unfavoriteMessage)
            case .editMessage:
                routes.on(route.method, route.path, use: controller.editMessage)
            case .toggleReaction:
                routes.on(route.method, route.path, use: controller.toggleReaction)
            case .recallMessage:
                routes.on(route.method, route.path, use: controller.recallMessage)
            case .startAIMessageStream:
                routes.on(route.method, route.path, use: controller.startAIMessageStream)
            case .cancelMessageStream:
                routes.on(route.method, route.path, use: controller.cancelMessageStream)
            case .markRead:
                routes.on(route.method, route.path, use: controller.markRead)
            case .clearConversationForSelf:
                routes.on(route.method, route.path, use: controller.clearConversationForSelf)
            case .deleteConversationForSelf:
                routes.on(route.method, route.path, use: controller.deleteConversationForSelf)
            case .createInvite:
                routes.on(route.method, route.path, use: controller.createInvite)
            case .listInvites:
                routes.on(route.method, route.path, use: controller.listInvites)
            case .revokeInvite:
                routes.on(route.method, route.path, use: controller.revokeInvite)
            case .joinInvite:
                routes.on(route.method, route.path, use: controller.joinInvite)
            case .leaveConversation:
                routes.on(route.method, route.path, use: controller.leaveConversation)
            }
        }
    }
}
