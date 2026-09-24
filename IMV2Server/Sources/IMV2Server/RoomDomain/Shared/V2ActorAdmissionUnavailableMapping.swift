import IMV2ActorContracts
import IMV2Core

public extension V2ActorAdmissionUnavailableWire {
    init(_ value: V2CommandAdmissionUnavailableReason) {
        switch value {
        case .missingShardLease: self = .missingShardLease
        case .expiredShardLease: self = .expiredShardLease
        }
    }

    func toDomain() -> V2CommandAdmissionUnavailableReason {
        switch self {
        case .missingShardLease: .missingShardLease
        case .expiredShardLease: .expiredShardLease
        }
    }
}
