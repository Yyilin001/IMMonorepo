import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 仅用于已获准的发送轮次。网关不能用此契约
/// 准入新的房间命令，或制造成功回执。
public protocol V2ActorGrantedSendBatching: Sendable {
    func acceptGrantedTurn(_ sends: [V2PreparedActorSend],
                           batchDeadline: ContinuousClock.Instant,
                           callDeadline: ContinuousClock.Instant) async throws
        -> [Result<V2SendMessageOutcome, any Error>]
    func retireActivation(_ token: V2RoomActivationToken) async
}

/// 将完整获准的房间轮次映射为一次有界批处理准入，
/// 再还原成有序的类型化结果。一个 SQL 分区可能先于另一分区回滚而提交，
/// 因此混合的持久化结果会让整个轮次以结果未知结束。
public struct V2ActorGrantedSendBatchAdapter: Sendable {
    private let batcher: any V2ActorGrantedSendBatching

    public init(batcher: any V2ActorGrantedSendBatching) {
        self.batcher = batcher
    }

    /// 宿主只在执行器关闭或被围栏排除后调用此方法。
    /// 它释放精确令牌占用的有界隔离槽位。
    public func retire(_ token: V2RoomActivationToken) async {
        await batcher.retireActivation(token)
    }

    public func execute(
        _ sends: [V2PreparedActorSend],
        batchDeadline: ContinuousClock.Instant,
        callDeadline: ContinuousClock.Instant = .now + .seconds(10)
    ) async throws -> [V2RoomMessagingResult] {
        let results: [Result<V2SendMessageOutcome, any Error>]
        do {
            results = try await batcher.acceptGrantedTurn(sends,
                batchDeadline: batchDeadline, callDeadline: callDeadline)
        } catch V2SendMessageAdmissionBatcherError.serverBusy {
            throw V2RoomCallFailure.notAccepted(.overloaded)
        } catch is CancellationError {
            throw V2RoomCallFailure.notAccepted(.cancelled)
        }
        // 若每次选定的 SQL 尝试都有回滚证明，
        // 整个获准轮次即可报告这一事实，无须退役激活。
        let rollbackFailures = results.compactMap { result -> V2RoomCallFailure? in
            guard case .failure(let error) = result,
                  let failure = error as? V2RoomCallFailure else { return nil }
            switch failure {
            case .notAccepted, .rolledBack: return failure
            case .outcomeUnknown: return nil
            }
        }
        if rollbackFailures.count == results.count, let first = rollbackFailures.first {
            throw first
        }
        // 驱动故障或结果不明的 SQL 提交不是类型化业务拒绝。
        // 只要任一参与项的持久化结果仍未确定，
        // 就不能将部分成功结果作为已提交轮次返回。
        for result in results {
            if case .failure(let error) = result,
               error is V2RoomTransactionOutcomeUnknown ||
               error is V2RoomActivationLeaseError ||
               (error as? V2RoomWriteStoreError) == .corruptPersistenceState ||
               V2ActorMessagingErrorWire(domainError: error) == nil {
                throw V2RoomCallFailure.outcomeUnknown
            }
        }
        return try results.map { result -> V2RoomMessagingResult in
            switch result {
            case .success(let outcome): return .send(.init(outcome))
            case .failure(let error):
                guard let failure = V2ActorMessagingErrorWire(domainError: error) else {
                    throw V2RoomCallFailure.outcomeUnknown
                }
                return .failure(failure)
            }
        }
    }
}
