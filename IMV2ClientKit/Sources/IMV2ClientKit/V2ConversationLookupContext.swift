import IMV2Core

/// Local routing facts for a subsequent authorized profile lookup. A direct
/// identity carries no cached name, avatar or permission to display either.
public enum V2ClientConversationLookupContext: Equatable, Sendable {
    case group(title: String)
    case direct(peerUserID: UserID)
}
