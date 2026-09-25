/// 供消息与管理操作共用；编码为稳定的原因字符串。
public enum V2ActorAdmissionUnavailableWire: String, Codable, Equatable, Sendable {
    case missingShardLease
    case expiredShardLease
}
