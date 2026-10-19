/// A destination in the authenticated app's shared navigation stack.
struct V2ConversationRoute: Hashable {
    let roomID: String
    var messageID: String? = nil
}
