import Foundation
import GRDB

extension GRDBV2LocalSyncStore {
    /// 读取推送意图的下一次尝试调度。
    ///
    /// 只有与当前安装绑定一致、尚未被确认、且已具备可用令牌引用
    /// （或明确处于关闭意图）的记录才会被纳入调度。
    ///
    /// - Parameters:
    ///   - scope: 当前本地账号与安装的作用域。
    ///   - ownerID: 推送意图的归属标识。
    /// - Returns: 下一次尝试时间与变更通知组成的调度。
    public nonisolated func pushIntentSchedule(scope: V2PushIntentScope, ownerID: UUID) -> V2CommandRetrySchedule {
        let pool = databasePool
        let query = """
            SELECT intent.next_attempt_at FROM v2_push_intent AS intent
            JOIN v2_local_installation AS account ON account.singleton = 1
            WHERE intent.singleton = 1 AND intent.device_id = ? AND intent.owner_id = ?
                AND account.user_id = ? AND account.binding = ? AND intent.pause_reason IS NULL
                AND intent.acknowledged_revision < intent.intent_revision
                AND (intent.desired_enabled = 0 OR intent.token_reference IS NOT NULL)
            """
        let values = [scope.deviceID.rawValue, ownerID.uuidString, scope.userID.rawValue, scope.installation.value.uuidString]
        return .init(nextAttemptAt: {
            try await pool.read { try Double.fetchOne($0, sql: query, arguments: StatementArguments(values)).map(Date.init(timeIntervalSince1970:)) }
        }, updates: {
            AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    do {
                        let observation = ValueObservation.tracking { try Double.fetchOne($0, sql: query, arguments: StatementArguments(values)) }.removeDuplicates()
                        for try await _ in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(()) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })
    }
}
