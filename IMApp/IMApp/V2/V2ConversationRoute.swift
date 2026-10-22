import Foundation
/// A destination in the authenticated app's shared navigation stack.
struct V2ConversationRoute: Hashable {
    let roomID: String
    var messageID: String? = nil
}

/// Local conversation identity remains distinct from a server room identifier.
struct V2LocalDirectConversationRoute: Hashable {
    let operationID: UUID
}

enum V2ConversationDestination: Hashable {
    case room(V2ConversationRoute)
    case localDirect(V2LocalDirectConversationRoute)

    init(roomID: String, messageID: String? = nil) {
        self = .room(.init(roomID: roomID, messageID: messageID))
    }
}
