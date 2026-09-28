import Foundation
import GRDB
import IMV2Core

extension GRDBV2LocalSyncStore: V2LocalPushIntentStoring {
    /// 由设备标识构造推送意图作用域。
    ///
    /// - Parameter deviceID: 目标设备。
    /// - Returns: 该设备的推送意图作用域。
    /// - Throws: 设备标识非法或本地安装绑定缺失时抛出。
    public func pushIntentScope(deviceID: DeviceID) throws -> V2PushIntentScope {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1"),
                  let user: String = row["user_id"], let binding = UUID(uuidString: row["binding"]) else { throw V2LocalPushIntentError.scopeMismatch }
            return try .init(userID: UserID(user), deviceID: deviceID, installation: .init(value: binding))
        }
    }

    public nonisolated func pushIntentUpdates(scope: V2PushIntentScope, ownerID: UUID) -> AsyncThrowingStream<V2LocalPushIntent, any Error> {
        let pool = databasePool
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let observation = ValueObservation.tracking { db in
                        try Self.ownedPushIntent(scope: scope, ownerID: ownerID, db: db)
                    }.removeDuplicates()
                    for try await value in observation.values(in: pool, bufferingPolicy: .bufferingNewest(1)) { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 读取指定作用域的推送意图。
    ///
    /// - Parameter scope: 目标作用域。
    /// - Returns: 现有意图；不存在时返回 `nil`。
    /// - Throws: 数据库读取失败时抛出。
    public func inspectPushIntent(scope: V2PushIntentScope) throws -> V2LocalPushIntent? {
        try databasePool.read { db in
            try Self.checkPushScope(scope, db: db)
            return try Self.readPushIntent(scope: scope, db: db)
        }
    }

    /// 激活新的推送所有者并占用更新修订。
    ///
    /// - Parameters:
    ///   - scope: 目标作用域。
    ///   - ownerID: 新所有者标识。
    ///   - initialPreference: 初始偏好。
    ///   - expected: 被替换的既有意图。
    /// - Returns: 激活后的意图。
    /// - Throws: 作用域或期望值不匹配时抛出。
    public func activatePushIntent(scope: V2PushIntentScope, ownerID: UUID, initialPreference: Bool, replacing expected: V2LocalPushIntent? = nil) throws -> V2LocalPushIntent {
        try databasePool.write { db in
            try Self.checkPushScope(scope, db: db)
            let observed = try Self.readPushIntent(scope: scope, db: db)
            if let observed, observed.scope.deviceID == scope.deviceID, observed.ownerID == ownerID { return observed }
            guard observed == expected else { throw V2LocalPushIntentError.staleOwner }
            var state: V2LocalPushIntent
            if let current = observed, current.scope.deviceID == scope.deviceID {
                // Activation means this owner can reacquire a fresh OS token.
                // Preserve an uncertain claim exactly across process restarts.
                state = current
                state.ownerID = ownerID
                state.desiredEnabled = state.preferenceEnabled
                state.tokenReference = nil
                let previousAttempts = state.attemptCount
                try Self.advancePushRevision(&state)
                state.attemptCount = previousAttempts
            } else {
                state = .init(scope: scope, ownerID: ownerID, preferenceEnabled: initialPreference, desiredEnabled: initialPreference,
                              revision: 1, acknowledgedRevision: 0, tokenReference: nil, claim: nil, epoch: nil,
                              attemptCount: 0, nextAttemptAt: .init(timeIntervalSince1970: 0), pauseReason: nil)
            }
            try Self.writePushIntent(state, db: db)
            return state
        }
    }

    /// 读取指定所有者的推送意图。
    ///
    /// - Parameters:
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 当前意图。
    /// - Throws: 记录缺失或所有者已过期时抛出。
    public func pushIntent(scope: V2PushIntentScope, ownerID: UUID) throws -> V2LocalPushIntent {
        try databasePool.read { try Self.ownedPushIntent(scope: scope, ownerID: ownerID, db: $0) }
    }

    /// 设置推送开关并占用新的修订。
    ///
    /// - Parameters:
    ///   - enabled: 目标开关状态。
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 更新后的意图。
    /// - Throws: 状态或所有者不匹配时抛出。
    public func setPushIntentEnabled(_ enabled: Bool, scope: V2PushIntentScope, ownerID: UUID) throws -> V2LocalPushIntent {
        try mutatePushIntent(scope: scope, ownerID: ownerID) { state in
            guard state.preferenceEnabled != enabled || state.desiredEnabled != enabled else { return }
            state.preferenceEnabled = enabled; state.desiredEnabled = enabled; state.tokenReference = nil
            try Self.advancePushRevision(&state)
        }
    }

    /// 暂存内存令牌引用。
    ///
    /// - Parameters:
    ///   - reference: 令牌引用。
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 更新后的意图。
    /// - Throws: 状态或所有者不匹配时抛出。
    public func stagePushToken(reference: UUID, scope: V2PushIntentScope, ownerID: UUID) throws -> V2LocalPushIntent {
        try mutatePushIntent(scope: scope, ownerID: ownerID) { state in
            guard state.desiredEnabled else { throw V2LocalPushIntentError.invalidState }
            guard state.tokenReference != reference else { return }
            state.tokenReference = reference
            try Self.advancePushRevision(&state)
        }
    }

    /// 准备登出并清理本地推送状态。
    ///
    /// - Parameters:
    ///   - scope: 目标作用域。
    ///   - ownerID: 所有者标识。
    /// - Returns: 更新后的意图。
    /// - Throws: 状态或所有者不匹配时抛出。
    public func preparePushSignOut(scope: V2PushIntentScope, ownerID: UUID) throws -> V2LocalPushIntent {
        try mutatePushIntent(scope: scope, ownerID: ownerID) { state in
            guard state.desiredEnabled else { return }
            state.desiredEnabled = false; state.tokenReference = nil
            try Self.advancePushRevision(&state)
        }
    }

    /// 以期望值做条件保存推送输入。
    ///
    /// - Parameters:
    ///   - preferenceEnabled: 用户偏好开关。
    ///   - desiredEnabled: 期望推送开关。
    ///   - tokenReference: 内存令牌引用。
    ///   - expected: 期望的当前意图。
    /// - Returns: 保存生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func savePushInput(preferenceEnabled: Bool, desiredEnabled: Bool, tokenReference: UUID?, expected: V2LocalPushIntent) throws -> Bool {
        guard (!desiredEnabled || preferenceEnabled), (desiredEnabled || tokenReference == nil) else { throw V2LocalPushIntentError.invalidState }
        return try comparePushIntent(expected) { state in
            guard state.preferenceEnabled != preferenceEnabled || state.desiredEnabled != desiredEnabled || state.tokenReference != tokenReference else { return }
            state.preferenceEnabled = preferenceEnabled; state.desiredEnabled = desiredEnabled; state.tokenReference = tokenReference
            try Self.advancePushRevision(&state)
        }
    }

    /// 以期望值做条件保存会话声明。
    ///
    /// - Parameters:
    ///   - claim: 待保存的会话声明。
    ///   - expected: 期望的当前意图。
    /// - Returns: 保存生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func savePushClaim(_ claim: V2PushIntentSessionClaim, expected: V2LocalPushIntent) throws -> Bool {
        try comparePushIntent(expected) { state in
            guard state.claim == nil && state.epoch == nil else { throw V2LocalPushIntentError.invalidState }
            state.claim = claim
        }
    }

    /// 以指定代次完成当前会话声明。
    ///
    /// - Parameters:
    ///   - epoch: 会话代次。
    ///   - expected: 期望的当前意图。
    /// - Returns: 完成生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func completePushClaim(epoch: UInt64, expected: V2LocalPushIntent) throws -> Bool {
        try comparePushIntent(expected) { state in
            guard let claim = state.claim, state.epoch == nil, epoch == claim.expectedEpoch + 1 else { throw V2LocalPushIntentError.invalidState }
            state.epoch = epoch; state.attemptCount = 0; state.nextAttemptAt = .init(timeIntervalSince1970: 0)
        }
    }

    /// 重启推送会话并占用新的代次。
    ///
    /// 只在调用方已重新确认为当前所有者之后显式恢复；绝不能因为收到陈旧会话响应就自动调用。
    ///
    /// - Parameter expected: 期望的当前意图。
    /// - Returns: 重启生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func restartPushIntentSession(expected: V2LocalPushIntent) throws -> Bool {
        try comparePushIntent(expected) { state in
            guard state.pauseReason != nil else { throw V2LocalPushIntentError.invalidState }
            state.claim = nil; state.epoch = nil; state.pauseReason = nil
            try Self.advancePushRevision(&state)
        }
    }

    /// 确认已同步到服务端的修订。
    ///
    /// - Parameter expected: 期望的当前意图。
    /// - Returns: 确认生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func acknowledgePushIntent(_ expected: V2LocalPushIntent) throws -> Bool {
        try comparePushIntent(expected) { state in
            guard state.version != nil && !state.waitingForToken else { throw V2LocalPushIntentError.invalidState }
            state.acknowledgedRevision = state.revision; state.attemptCount = 0
        }
    }

    /// 安排下一次重试时刻。
    ///
    /// - Parameters:
    ///   - date: 下次尝试时刻。
    ///   - expected: 期望的当前意图。
    /// - Returns: 更新生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func retryPushIntent(at date: Date, expected: V2LocalPushIntent) throws -> Bool {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw V2LocalPushIntentError.invalidState }
        return try comparePushIntent(expected) { state in
            state.attemptCount = min(Int(Int32.max), state.attemptCount + 1)
            state.nextAttemptAt = date
        }
    }

    /// A delayed throttle can constrain a newer input owned by the same account
    /// activity, while never completing it or allowing an old owner to mutate it.
    func preserveSupersededPushServiceCooldown(until date: Date, expected: V2LocalPushIntent) throws {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
              date.timeIntervalSince1970 < 1e300 else { throw V2LocalPushIntentError.invalidState }
        try databasePool.write { db in
            try Self.checkPushScope(expected.scope, db: db)
            guard var current = try Self.readPushIntent(scope: expected.scope, db: db),
                  current.ownerID == expected.ownerID, current.scope == expected.scope,
                  current != expected, date > current.nextAttemptAt else { return }
            current.nextAttemptAt = date
            try Self.writePushIntent(current, db: db)
        }
    }

    /// 暂停推送意图并记录原因。
    ///
    /// - Parameters:
    ///   - reason: 暂停原因。
    ///   - expected: 期望的当前意图。
    /// - Returns: 更新生效时为 `true`。
    /// - Throws: 数据库写入失败时抛出。
    public func pausePushIntent(_ reason: V2PushIntentPauseReason, expected: V2LocalPushIntent) throws -> Bool {
        try comparePushIntent(expected) { $0.pauseReason = reason }
    }

    private func mutatePushIntent(scope: V2PushIntentScope, ownerID: UUID, mutation: (inout V2LocalPushIntent) throws -> Void) throws -> V2LocalPushIntent {
        try databasePool.write { db in
            var state = try Self.ownedPushIntent(scope: scope, ownerID: ownerID, db: db)
            try mutation(&state)
            try Self.writePushIntent(state, db: db)
            return state
        }
    }

    private func comparePushIntent(_ expected: V2LocalPushIntent, mutation: (inout V2LocalPushIntent) throws -> Void) throws -> Bool {
        try databasePool.write { db in
            try Self.checkPushScope(expected.scope, db: db)
            guard var current = try Self.readPushIntent(scope: expected.scope, db: db), current == expected else { return false }
            try mutation(&current)
            try Self.writePushIntent(current, db: db)
            return true
        }
    }

    private static func advancePushRevision(_ state: inout V2LocalPushIntent) throws {
        guard state.revision < UInt64(Int64.max) else { throw V2LocalPushIntentError.versionExhausted }
        state.revision += 1; state.attemptCount = 0
        // A new input revision cannot bypass a persisted service cooldown.
        // Do not silently resume a server conflict or authentication failure.
    }

    private static func checkPushScope(_ scope: V2PushIntentScope, db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1"),
              (row["binding"] as String?) == scope.installation.value.uuidString,
              (row["user_id"] as String?) == scope.userID.rawValue else { throw V2LocalPushIntentError.scopeMismatch }
    }

    private static func ownedPushIntent(scope: V2PushIntentScope, ownerID: UUID, db: Database) throws -> V2LocalPushIntent {
        try checkPushScope(scope, db: db)
        guard let state = try readPushIntent(scope: scope, db: db), state.scope.deviceID == scope.deviceID, state.ownerID == ownerID else { throw V2LocalPushIntentError.staleOwner }
        return state
    }

    private static func optionalPushIntentInteger(_ row: Row, column: String) throws -> Int64? {
        let value: DatabaseValue = row[column]
        if value.isNull { return nil }
        guard case .int64(let integer) = value.storage else { throw V2LocalPushIntentError.invalidState }
        return integer
    }

    private static func pushIntentInteger(_ row: Row, column: String) throws -> Int64 {
        guard let value = try optionalPushIntentInteger(row, column: column) else { throw V2LocalPushIntentError.invalidState }
        return value
    }

    private static func readPushIntent(scope: V2PushIntentScope, db: Database) throws -> V2LocalPushIntent? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_push_intent WHERE singleton = 1") else { return nil }
        let storedScope = try V2PushIntentScope(userID: scope.userID, deviceID: DeviceID(row["device_id"]), installation: scope.installation)
        guard let owner = UUID(uuidString: row["owner_id"]) else { throw V2LocalPushIntentError.invalidState }
        let revision = try pushIntentInteger(row, column: "intent_revision"), ack = try pushIntentInteger(row, column: "acknowledged_revision")
        guard revision > 0, ack >= 0, ack <= revision else { throw V2LocalPushIntentError.invalidState }
        let storedAttempts = try pushIntentInteger(row, column: "attempt_count")
        guard (0...Int64(Int32.max)).contains(storedAttempts) else { throw V2LocalPushIntentError.invalidState }
        let attemptCount = Int(storedAttempts)
        let nextAttemptAt: Double = row["next_attempt_at"]
        guard nextAttemptAt >= 0, nextAttemptAt < 1e300 else { throw V2LocalPushIntentError.invalidState }
        let tokenText: String? = row["token_reference"], claimText: String? = row["claim_id"]
        let token = tokenText.flatMap(UUID.init(uuidString:)), claimID = claimText.flatMap(UUID.init(uuidString:))
        guard (tokenText == nil) == (token == nil), (claimText == nil) == (claimID == nil) else { throw V2LocalPushIntentError.invalidState }
        let expected = try optionalPushIntentInteger(row, column: "expected_epoch"), epoch = try optionalPushIntentInteger(row, column: "session_epoch")
        let claim: V2PushIntentSessionClaim?
        if let claimID, let expected, expected >= 0 { claim = try .init(requestID: claimID, expectedEpoch: UInt64(expected)) }
        else { guard claimID == nil && expected == nil else { throw V2LocalPushIntentError.invalidState }; claim = nil }
        if let epoch { guard epoch > 0, let claim, UInt64(epoch) == claim.expectedEpoch + 1 else { throw V2LocalPushIntentError.invalidState } }
        let reasonText: String? = row["pause_reason"]
        let reason = reasonText.flatMap(V2PushIntentPauseReason.init(rawValue:))
        guard (reasonText == nil) == (reason == nil) else { throw V2LocalPushIntentError.invalidState }
        return .init(scope: storedScope, ownerID: owner, preferenceEnabled: row["preference_enabled"], desiredEnabled: row["desired_enabled"],
                     revision: UInt64(revision), acknowledgedRevision: UInt64(ack), tokenReference: token, claim: claim,
                     epoch: epoch.map(UInt64.init), attemptCount: attemptCount, nextAttemptAt: Date(timeIntervalSince1970: nextAttemptAt), pauseReason: reason)
    }

    private static func writePushIntent(_ state: V2LocalPushIntent, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO v2_push_intent (singleton, device_id, owner_id, preference_enabled, desired_enabled, intent_revision, acknowledged_revision,
                token_reference, claim_id, expected_epoch, session_epoch, attempt_count, next_attempt_at, pause_reason)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET device_id=excluded.device_id, owner_id=excluded.owner_id, preference_enabled=excluded.preference_enabled,
                desired_enabled=excluded.desired_enabled, intent_revision=excluded.intent_revision, acknowledged_revision=excluded.acknowledged_revision,
                token_reference=excluded.token_reference, claim_id=excluded.claim_id, expected_epoch=excluded.expected_epoch, session_epoch=excluded.session_epoch,
                attempt_count=excluded.attempt_count, next_attempt_at=excluded.next_attempt_at, pause_reason=excluded.pause_reason
            """, arguments: [state.scope.deviceID.rawValue, state.ownerID.uuidString, state.preferenceEnabled, state.desiredEnabled, Int64(state.revision), Int64(state.acknowledgedRevision),
                              state.tokenReference?.uuidString, state.claim?.requestID.uuidString, state.claim.map { Int64($0.expectedEpoch) }, state.epoch.map(Int64.init), state.attemptCount, state.nextAttemptAt.timeIntervalSince1970, state.pauseReason?.rawValue])
    }
}
