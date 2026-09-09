import Foundation
import Crypto
import IMV2Core
#if canImport(Security)
import Security
#endif

/// 待执行注册取消的不可变快照，保留完整证明、失败次数、重试时间及暂停原因。
public struct V2DeviceRegistrationCancellationJob: Codable, Equatable, Sendable {
    /// 停止自动重试的原因：请求无效或响应无效，需显式恢复。
    public enum PauseReason: String, Codable, Sendable { case invalidRequest, invalidResponse }
    /// 签发前保存且重试中不变的取消材料。
    public let cancellation: V2DeviceRegistrationCancellation
    /// 已记录失败次数，达到 UInt32 最大值后保持饱和。
    public let attempts: UInt32
    /// 未暂停时允许再次执行的时间。
    public let nextAttemptAt: Date
    /// 非空时停止自动调度。
    public let pauseReason: PauseReason?
}

/// 按账户作用域管理待注册身份、取消任务与历史注册恢复证据。
///
/// 与安装身份和已建立的认证凭证分开持有。每次账本读改写通过同步存储完成，无挂起点；同一应用凭证命名空间应仅有一个所有者。
/// 正常容量为 256 项，旧记录恢复允许额外预留一项取得新账户因子。
public actor V2DeviceRegistrationStore {
    /// 同步替换完整账本的存储边界。
    private let persistence: any V2DeviceRegistrationPersisting
    /// 为新注册生成设备与操作身份的可注入工厂。
    private let makeUUID: @Sendable () -> UUID
    /// 准备与检查签发截止时间的时钟。
    private let now: @Sendable () -> Date
    /// 保存成功后唤醒调度器的变更订阅。
    private var observers: [UUID: AsyncThrowingStream<Void, any Error>.Continuation] = [:]
    /// 只接收取消队列聚合状态的展示订阅。
    private var statusObservers: [UUID: AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error>.Continuation] = [:]

    /// 创建指定 Keychain 命名空间的注册所有者，默认使用系统 UUID 与当前日期，不立即读取账本。
    public init(service: String) {
        persistence = V2KeychainDeviceRegistrationPersistence(service: service)
        makeUUID = UUID.init
        now = Date.init
    }

    /// 注入同步存储、UUID 工厂与时钟，便于隔离验证注册及恢复流程。
    init(persistence: any V2DeviceRegistrationPersisting, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init) {
        self.persistence = persistence
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 在取得账户断言前保存注册身份，为同一账户复用尚未过期的操作。
    ///
    /// - Parameter accountHandle: 用于本地作用域映射的账户名，先转小写再验证字符集和长度。
    /// - Returns: 绑定本次精确操作的不可变注册句柄，兼作设备身份与操作存储接口。
    /// - Throws: 账户名无效、容量不足、取消材料构造或持久化错误。
    ///
    /// 相同作用域的过期操作先转入取消队列，再创建新的设备 UUID 与操作 UUID。不同账户不会覆盖彼此的待注册记录。
    /// 总数为 256 且该作用域存在历史恢复记录时，允许使用第 257 项完成恢复；普通注册不能使用该预留位置。
    public func prepare(accountHandle: String) throws -> V2PreparedDeviceRegistration {
        let scope = try Self.scope(accountHandle)
        var ledger = try load()
        let registration: V2PendingDeviceCredentialRegistration
        if let pending = ledger.pending[scope], pending.cancellation.issueBefore > now() {
            registration = pending
        } else {
            if let expired = ledger.pending.removeValue(forKey: scope) {
                try abandon(expired.cancellation, in: &ledger)
            }
            // One reserved entry lets a full legacy archive obtain a fresh
            // factor and clean itself. Normal registration cannot use it.
            guard ledger.count < 256 || (ledger.count == 256 && ledger.legacy[scope] != nil) else {
                throw V2DeviceCredentialRegistrationOperationStoreError.capacityExceeded
            }
            registration = try .prepare(deviceID: DeviceID(makeUUID().uuidString), operationID: makeUUID(), now: now())
            ledger.pending[scope] = registration
            try save(ledger)
        }
        return .init(registration: registration, scope: scope, owner: self)
    }

    /// 将全部待注册操作转入取消队列，再清空待注册集合并整体保存。
    ///
    /// 调用方须先使交互认证失效并完成本地退出。取消材料保留至服务端确认，迟到完成者不能删除后续不同操作。
    /// - Throws: 材料冲突、账本读取或保存错误。
    public func discardPendingRegistrations() throws {
        var ledger = try load()
        for pending in ledger.pending.values { try abandon(pending.cancellation, in: &ledger) }
        ledger.pending.removeAll()
        try save(ledger)
    }

    /// 读取按操作 UUID 排序的完整取消材料，包括暂停和未到期任务，不改变重试状态。
    public func pendingCancellations() throws -> [V2DeviceRegistrationCancellation] {
        try cancellationJobs().map(\.cancellation)
    }

    /// 仅在持久化取消材料完全匹配时删除任务，缺失或不匹配则返回。
    ///
    /// - Parameter cancellation: 已取得服务端终结结果的材料。
    /// - Throws: 账本读取或保存错误。
    ///
    /// 此入口比较取消身份，不比较尝试次数与暂停状态；执行器使用完整任务快照的完成入口。
    public func completeCancellation(_ cancellation: V2DeviceRegistrationCancellation) throws {
        var ledger = try load()
        guard ledger.abandoned[cancellation.operationID.uuidString]?.cancellation == cancellation else { return }
        ledger.abandoned[cancellation.operationID.uuidString] = nil
        try save(ledger)
    }

    /// 读取仍待显式恢复的历史注册数量；账本读取可能先执行格式迁移。
    public func legacyRecoveryCount() throws -> Int { try load().legacy.count }

    /// 检查任务取消及精确待注册句柄仍有效后，读取该账户作用域的历史目标。
    fileprivate func legacy(for registration: V2PendingDeviceCredentialRegistration, scope: String) throws -> V2LegacyDeviceRegistration? {
        try Task.checkCancellation()
        let ledger = try load()
        guard ledger.pending[scope] == registration else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return ledger.legacy[scope]
    }

    /// 检查取消、待注册句柄与历史目标一致后删除历史证据；历史记录已不存在时成功返回，其余身份不匹配报告 malformedRecord。
    fileprivate func completeLegacy(_ legacy: V2LegacyDeviceRegistration, registration: V2PendingDeviceCredentialRegistration, scope: String) throws {
        try Task.checkCancellation()
        var ledger = try load()
        guard ledger.pending[scope] == registration else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        guard let current = ledger.legacy[scope] else { return }
        guard current == legacy else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        ledger.legacy[scope] = nil
        try save(ledger)
    }

    /// 在冷启动、允许交互注册之前清理中断的待注册记录。
    ///
    /// - Parameter record: 已持久化的认证记录；无待撤销标记且设备相同则视为已接纳，不将该操作转入取消队列。
    /// - Throws: 账本或取消材料保存错误。
    ///
    /// 本实现依赖设备身份是唯一服务端会话身份且不复用，不额外比较用户或操作 UUID。处理完后清空全部待注册记录，未归属记录仍在取消队列中。
    public func recoverUnclaimed(ownedBy record: V2AuthCredentialRecord?) throws {
        var ledger = try load()
        guard !ledger.pending.isEmpty else { return }
        for pending in ledger.pending.values {
            let owned = record?.pendingRevocationOperationID == nil && record?.credentials.deviceID == pending.deviceID
            if !owned { try abandon(pending.cancellation, in: &ledger) }
        }
        ledger.pending.removeAll()
        try save(ledger)
    }

    /// 读取完整取消任务快照，按操作 UUID 字符串排序，包括暂停及未到期任务。
    public func cancellationJobs() throws -> [V2DeviceRegistrationCancellationJob] {
        try load().abandoned.values.sorted { $0.cancellation.operationID.uuidString < $1.cancellation.operationID.uuidString }
    }

    /// 要求有限调度时间，选择未暂停且已到重试时间的最多四项，按重试时间及操作 UUID 排序；不以本地签发期限自动完成。
    func dueCancellations(at now: Date) throws -> [V2DeviceRegistrationCancellationJob] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return Array(try cancellationJobs().filter { $0.pauseReason == nil && $0.nextAttemptAt <= now }.sorted {
            if $0.nextAttemptAt != $1.nextAttemptAt { return $0.nextAttemptAt < $1.nextAttemptAt }
            return $0.cancellation.operationID.uuidString < $1.cancellation.operationID.uuidString
        }.prefix(4))
    }

    /// 检查取消并仅删除仍与输入完整快照相同的任务，避免迟到结果清除已更新任务。
    func completeCancellationJob(_ job: V2DeviceRegistrationCancellationJob) throws {
        try Task.checkCancellation()
        var ledger = try load()
        let key = job.cancellation.operationID.uuidString
        guard ledger.abandoned[key] == job else { return }
        ledger.abandoned[key] = nil
        try save(ledger)
    }

    /// 检查取消与有限重试日期，仅更新仍匹配的任务快照；失败次数饱和递增，保留稳定取消身份。
    func recordCancellationFailure(_ job: V2DeviceRegistrationCancellationJob, retryAt: Date,
        pauseReason: V2DeviceRegistrationCancellationJob.PauseReason? = nil) throws {
        try Task.checkCancellation()
        guard retryAt.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        var ledger = try load()
        let key = job.cancellation.operationID.uuidString
        guard ledger.abandoned[key] == job else { return }
        ledger.abandoned[key] = .init(cancellation: job.cancellation, attempts: job.attempts == .max ? .max : job.attempts + 1,
            nextAttemptAt: retryAt, pauseReason: pauseReason)
        try save(ledger)
    }

    /// 响应显式恢复操作，解除全部暂停并设为立即可执行，保留失败次数；普通退避任务不变，没有变化时不写入。
    public func retryPausedCancellations() throws {
        try Task.checkCancellation()
        var ledger = try load()
        var changed = false
        for (key, job) in ledger.abandoned where job.pauseReason != nil {
            ledger.abandoned[key] = .init(cancellation: job.cancellation, attempts: job.attempts, nextAttemptAt: .distantPast, pauseReason: nil)
            changed = true
        }
        if changed { try save(ledger) }
    }

    /// 订阅取消队列聚合状态，立即发送初始快照，只缓冲最新一项。
    ///
    /// - Returns: 不含设备或证明的状态流；初始账本读取失败时以错误结束。
    ///
    /// 初始读取与观察者注册处于同一 actor 执行段；pending 注册与 legacy 恢复记录不计入此队列状态。
    public func cancellationStatusUpdates() -> AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        do {
            let ledger = try load()
            statusObservers[id] = stream.continuation
            stream.continuation.yield(status(ledger))
            stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeStatusObserver(id) } }
        } catch { stream.continuation.finish(throwing: error) }
        return stream.stream
    }

    /// 移除结束的展示订阅，不改变账本。
    private func removeStatusObserver(_ id: UUID) { statusObservers[id] = nil }
    /// 仅统计 abandoned 取消队列；空为 empty，任一暂停为 paused，否则为 pending。
    private func status(_ ledger: Ledger) -> V2DeviceRevocationQueueStatus {
        if ledger.abandoned.isEmpty { return .empty }
        return ledger.abandoned.values.contains { $0.pauseReason != nil } ? .paused : .pending
    }

    /// 提供未暂停取消任务的最早执行时间及保存后的变更流，交给通用重试调度器。
    func cancellationRetrySchedule() -> V2CommandRetrySchedule {
        .init(nextAttemptAt: { try await self.cancellationJobs().filter { $0.pauseReason == nil }.map(\.nextAttemptAt).min() },
            updates: { await self.updates() })
    }

    /// 注册只保留最新提示的调度流，不发送初始事件；最早执行时间由调度器另行读取。
    private func updates() -> AsyncThrowingStream<Void, any Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }
    /// 移除结束的调度订阅。
    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// 在内存账本中加入立即可执行的取消任务；相同操作材料重复加入时保留已有退避与暂停状态，冲突则抛出 malformedRecord。
    private func abandon(_ cancellation: V2DeviceRegistrationCancellation, in ledger: inout Ledger) throws {
        let key = cancellation.operationID.uuidString
        if let prior = ledger.abandoned[key] {
            guard prior.cancellation == cancellation else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
            return // Preserve an existing job's retry and pause state.
        }
        ledger.abandoned[key] = .init(cancellation: cancellation, attempts: 0, nextAttemptAt: .distantPast, pauseReason: nil)
    }

    /// 要求持久化作用域仍对应同一完整待注册操作，否则报告 malformedRecord。
    fileprivate func requirePending(_ registration: V2PendingDeviceCredentialRegistration, scope: String) throws {
        guard try load().pending[scope] == registration else {
            throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord
        }
    }

    /// 仅移除仍与输入相同的待注册操作，旧句柄不能清除后续注册。
    fileprivate func finish(_ registration: V2PendingDeviceCredentialRegistration, scope: String) throws {
        var ledger = try load()
        guard ledger.pending[scope] == registration else { return }
        ledger.pending[scope] = nil
        try save(ledger)
    }

    /// 读取并校验账本，缺失时返回空版本 3 账本；版本 1 或 2 在读取中迁移并保存。
    ///
    /// 版本 3 验证总数最多 257、作用域格式、历史设备 UUID、取消任务键及有限重试时间。
    /// 版本 2 的取消材料迁移为立即可执行任务；版本 1 只有身份而没有证明，保留为 legacy 证据，不为旧请求伪造取消权限。
    /// - Throws: 格式或容量约束不满足时报告 malformedRecord，存储和迁移保存错误直接传播。
    private func load() throws -> Ledger {
        guard let data = try persistence.load() else { return .init() }
        if let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 3,
           ledger.count <= 257, ledger.pending.keys.allSatisfy(Self.validScope),
           ledger.legacy.keys.allSatisfy(Self.validScope),
           ledger.legacy.values.allSatisfy({ UUID(uuidString: $0.deviceID.rawValue) != nil }),
           ledger.abandoned.allSatisfy({ $0.key == $0.value.cancellation.operationID.uuidString && $0.value.nextAttemptAt.timeIntervalSinceReferenceDate.isFinite }) {
            return ledger
        }
        if let old = try? JSONDecoder().decode(ProofLedger.self, from: data), old.version == 2,
           old.pending.count + old.abandoned.count + old.legacy.count <= 256,
           old.pending.keys.allSatisfy(Self.validScope), old.legacy.keys.allSatisfy(Self.validScope),
           old.legacy.values.allSatisfy({ UUID(uuidString: $0.deviceID.rawValue) != nil }),
           old.abandoned.allSatisfy({ $0.key == $0.value.operationID.uuidString }) {
            var upgraded = Ledger()
            upgraded.pending = old.pending
            upgraded.legacy = old.legacy
            for cancellation in old.abandoned.values { try abandon(cancellation, in: &upgraded) }
            try save(upgraded)
            return upgraded
        }
        // Old IDs cannot be upgraded into authority over a request already
        // sent. Keep them as explicit legacy recovery evidence and rotate.
        guard let old = try? JSONDecoder().decode(LegacyLedger.self, from: data), old.version == 1,
              old.pending.count <= 256, old.pending.keys.allSatisfy(Self.validScope),
              old.pending.values.allSatisfy({ UUID(uuidString: $0.deviceID.rawValue) != nil })
        else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        var upgraded = Ledger()
        upgraded.legacy = old.pending
        try save(upgraded)
        return upgraded
    }

    /// 保存完整版本化账本，三类记录均为空时删除项目；持久化成功后才通知调度及聚合状态观察者。
    private func save(_ ledger: Ledger) throws {
        if ledger.count == 0 { try persistence.delete() }
        else { try persistence.save(JSONEncoder().encode(ledger)) }
        for observer in observers.values { observer.yield(()) }
        let snapshot = status(ledger)
        for observer in statusObservers.values { observer.yield(snapshot) }
    }

    /// 验证本地作用域键为 64 个小写十六进制 ASCII 字符。
    private static func validScope(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// 将账户名小写化，要求 3 到 64 字节且仅含小写字母、数字、下划线或连字符，再生成带用途前缀的 SHA256 十六进制键。
    ///
    /// 账本不保存明文账户名；此摘要仅用于本地查找，不是认证证明，也不保证账户名不可被猜测。
    private static func scope(_ accountHandle: String) throws -> String {
        let canonical = accountHandle.lowercased()
        let bytes = Array(canonical.utf8)
        guard (3 ... 64).contains(bytes.count), bytes.allSatisfy({
            (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 || $0 == 45
        }) else { throw V2AccountAuthenticationError.invalidAccountHandle }
        // Account handles are not persisted in plaintext. This digest is only
        // a local lookup key; it is not an authentication or privacy proof.
        return SHA256.hash(data: Data(("password-account-v1\0" + canonical).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// 版本 3 账本，分别保存待注册操作、带重试状态的取消任务和旧版恢复证据。
    private struct Ledger: Codable {
        var version = 3
        var pending: [String: V2PendingDeviceCredentialRegistration] = [:]
        var abandoned: [String: V2DeviceRegistrationCancellationJob] = [:]
        var legacy: [String: LegacyRegistration] = [:]
        var count: Int { pending.count + abandoned.count + legacy.count }
    }
    /// 版本 2 迁移输入，取消队列尚未包含重试次数、时间及暂停状态。
    private struct ProofLedger: Decodable {
        let version: Int
        let pending: [String: V2PendingDeviceCredentialRegistration]
        let abandoned: [String: V2DeviceRegistrationCancellation]
        let legacy: [String: LegacyRegistration]
    }
    /// 版本 1 迁移输入，仅有历史设备及操作身份，不含可追溯的取消证明。
    private struct LegacyLedger: Decodable {
        let version: Int
        let pending: [String: LegacyRegistration]
    }
    /// 账本历史恢复字段复用的旧注册目标类型。
    private typealias LegacyRegistration = V2LegacyDeviceRegistration
}

/// 账户因子与凭证签发器共享的不可变注册句柄。
///
/// 每次设备读取和操作存储调用都绑定精确待注册尝试；后续替换或清理后旧句柄不能接管新记录。
public struct V2PreparedDeviceRegistration: V2DeviceIdentityProvider, V2DeviceCredentialRegistrationOperationStore {
    /// 本句柄不可变的待注册快照。
    private let registration: V2PendingDeviceCredentialRegistration
    /// 账户查找摘要键。
    private let scope: String
    /// 串行比较与保存注册账本的所有者。
    private let owner: V2DeviceRegistrationStore

    /// 由注册所有者创建绑定精确快照和作用域的句柄。
    fileprivate init(registration: V2PendingDeviceCredentialRegistration, scope: String, owner: V2DeviceRegistrationStore) {
        self.registration = registration
        self.scope = scope
        self.owner = owner
    }

    /// 确认待注册快照仍有效后返回设备身份，否则抛出存储错误。
    public func deviceID() async throws -> DeviceID {
        try await owner.requirePending(registration, scope: scope)
        return registration.deviceID
    }

    /// 校验句柄后返回固定注册快照，失效时抛出错误而不是返回 nil。
    public func load() async throws -> V2PendingDeviceCredentialRegistration? {
        try await owner.requirePending(registration, scope: scope)
        return registration
    }

    /// 仅接受与本句柄相同的注册值并核对持久化所有权；不重复写入或替换注册。
    public func save(_ pending: V2PendingDeviceCredentialRegistration) async throws {
        guard pending == registration else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        try await owner.requirePending(registration, scope: scope)
    }

    /// 条件完成当前句柄对应注册，旧句柄不会删除不同的后续记录。
    public func delete() async throws {
        try await owner.finish(registration, scope: scope)
    }

    /// 包装账户因子，在返回断言用于签发前先完成同作用域历史目标清理；不立即发起请求。
    public func recoveringLegacyRegistration(using provider: any V2DeviceBoundAccountAssertionProvider,
        client: any V2LegacyRegistrationCancellationClient) -> any V2DeviceBoundAccountAssertionProvider {
        LegacyRecoveringAssertionProvider(lease: self, provider: provider, client: client)
    }

    /// 通过所有者核对当前句柄并读取历史恢复目标。
    fileprivate func legacy() async throws -> V2LegacyDeviceRegistration? {
        try await owner.legacy(for: registration, scope: scope)
    }

    /// 通过所有者核对当前句柄及目标后删除历史证据。
    fileprivate func completeLegacy(_ legacy: V2LegacyDeviceRegistration) async throws {
        try await owner.completeLegacy(legacy, registration: registration, scope: scope)
    }
}

/// 在签发前完成旧注册清理的账户断言包装器，共享当前注册句柄。
private struct LegacyRecoveringAssertionProvider: V2DeviceBoundAccountAssertionProvider {
    /// 当前不可变注册句柄。
    let lease: V2PreparedDeviceRegistration
    /// 取得新账户因子的底层提供者。
    let provider: any V2DeviceBoundAccountAssertionProvider
    /// 执行精确历史注册取消的客户端。
    let client: any V2LegacyRegistrationCancellationClient

    /// 核对当前设备及句柄，取得账户断言后先取消已读取的历史目标并清除证据，最后返回同一断言；每个阶段检查取消，失败不继续签发。
    func accountAssertion(for deviceID: DeviceID) async throws -> String {
        try Task.checkCancellation()
        guard try await lease.deviceID() == deviceID else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        let legacy = try await lease.legacy()
        try Task.checkCancellation()
        let assertion = try await provider.accountAssertion(for: deviceID)
        try Task.checkCancellation()
        _ = try await lease.deviceID()
        if let legacy {
            try await client.cancel(legacy, accountAssertion: assertion, assertionDeviceID: deviceID)
            try Task.checkCancellation()
            try await lease.completeLegacy(legacy)
        }
        try Task.checkCancellation()
        return assertion
    }
}

/// 同步完整账本存储边界，使 actor 能在无 await 的执行段内完成读取、比较和写入。
protocol V2DeviceRegistrationPersisting: Sendable {
    /// 读取完整账本字节，不存在返回 nil，失败抛出错误。
    func load() throws -> Data?
    /// 同步保存完整账本，返回成功后才可发布状态变更。
    func save(_ data: Data) throws
    /// 删除整个账本存储项，缺失项应视为成功。
    func delete() throws
}

/// 单个 Keychain 通用密码项的账本适配器；新项目设备限定且首次解锁后可访问，更新仅替换数据。
private struct V2KeychainDeviceRegistrationPersistence: V2DeviceRegistrationPersisting {
    /// 账本 Keychain 服务命名空间。
    let service: String

    #if canImport(Security)
    /// 以通用密码类别、服务名与固定账户 device-registration-ledger-v1 定位项目。
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "device-registration-ledger-v1"]
    }

    /// 读取唯一匹配项并要求 Data 类型，不存在返回 nil，系统或类型错误明确报告。
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2DeviceCredentialRegistrationOperationStoreError.malformedRecord }
        return data
    }

    /// 先更新项目数据，仅在不存在时插入；插入设置首次解锁后且仅限本设备保护级别。
    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }

    /// 删除匹配项目，不存在视为成功。
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    /// 将不可访问、解码及认证失败分别映射为 unavailable、malformedRecord、permanentlyInvalidated，其余保留状态码。
    private func error(_ status: OSStatus) -> V2DeviceCredentialRegistrationOperationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        case errSecAuthFailed: .permanentlyInvalidated
        default: .unexpectedStatus(status)
        }
    }
    #else
    /// 当前平台不支持 Security，始终抛出 unavailable。
    func load() throws -> Data? { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    /// 当前平台不支持 Security，不保存输入并抛出 unavailable。
    func save(_: Data) throws { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    /// 当前平台不支持 Security，始终抛出 unavailable。
    func delete() throws { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
    #endif
}
