/// A connection-local privacy ceiling. Allowing publication never overrides
/// the authenticated account's authoritative online-presence preference.
/// This ephemeral control is reapplied at authentication after reconnect.
public enum V2PresencePublicationMode:String,Codable,Equatable,Sendable {
    case suppressed
    case allowWhenAuthorized
}
