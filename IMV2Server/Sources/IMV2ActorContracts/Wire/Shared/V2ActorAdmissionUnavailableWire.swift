/// Shared by messaging and administration; encoded as the stable reason string.
public enum V2ActorAdmissionUnavailableWire: String, Codable, Equatable, Sendable {
    case missingShardLease
    case expiredShardLease
}
