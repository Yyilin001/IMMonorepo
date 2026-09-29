import IMV2ServerContracts
import IMV2ActorContracts

/// 只有明确证明没有业务写入被接受，才可判定为回滚。
/// 驱动、取消和 COMMIT 后的故障都会保守地退役整个轮次。
package func v2RoomDomainCompletion<Value: Sendable>(_ error: any Error) -> V2RoomTransactionCompletion<Value> {
    if let failure = error as? V2RoomCallFailure {
        switch failure {
        case .notAccepted(let reason), .rolledBack(let reason): return .rolledBack(reason)
        case .outcomeUnknown: return .outcomeUnknown
        }
    }
    if let failure = error as? V2RoomActivationLeaseError {
        switch failure {
        case .roomNotFound: return .rolledBack(.notFound)
        case .ownerChanged, .activationChanged: return .rolledBack(.staleActivation)
        case .leaseExpired: return .rolledBack(.leaseLost)
        case .epochExhausted, .outcomeUnknown: return .outcomeUnknown
        }
    }
    if error is V2RoomOwnerFenceError { return .rolledBack(.staleActivation) }
    if let failure = error as? V2HostRoomRecoveryBatchError {
        switch failure {
        case .busy: return .rolledBack(.overloaded)
        case .deadlineExceeded: return .rolledBack(.deadlineExceeded)
        case .oversized, .corruptResult: return .outcomeUnknown
        }
    }
    return .outcomeUnknown
}
