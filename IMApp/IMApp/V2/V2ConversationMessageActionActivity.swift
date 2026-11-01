import Observation

/// Shared by ordinary message actions and group pinning in one conversation.
/// The state lives here so extracting either feature preserves mutual exclusion.
@MainActor
@Observable
final class V2ConversationMessageActionActivity {
    private var messageIDs: Set<String> = []

    func contains(_ messageID: String) -> Bool { messageIDs.contains(messageID) }
    func begin(_ messageID: String) -> Bool { messageIDs.insert(messageID).inserted }
    func finish(_ messageID: String) { messageIDs.remove(messageID) }
}
