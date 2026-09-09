import Foundation
import IMV2Core
#if canImport(Security)
import Security
#endif

/// 独立设备撤销意图，包含撤销权限但不包含访问令牌或刷新凭证。
///
/// 不能用于建立新登录；其凭证仍是敏感材料，不应暴露给界面或日志。操作身份随持久化重试保持稳定。
public struct V2DeviceRevocationIntent: Codable, Equatable, Sendable {
    /// 撤销目标用户。
    public let userID: UserID
    /// 撤销目标设备。
    public let deviceID: DeviceID
    /// 仅授权撤销的敏感设备凭证。
    public let credential: V2DeviceRevocationCredential
    /// 服务端签发的撤销凭证期限；本地时钟不能据此确认任务完成。
    public let expiresAt: Date
    /// 跨持久化重试稳定的撤销操作身份。
    public let operationID: UUID

    /// 从完整认证凭证中仅提取撤销所需材料，并绑定调用方提供的稳定操作身份。
    public init(credentials: V2AuthCredentials, operationID: UUID) {
        userID = credentials.userID
        deviceID = credentials.deviceID
        credential = credentials.revocationCredential
        expiresAt = credentials.revocationCredentialExpiresAt
        self.operationID = operationID
    }
}

/// 接收并持久化撤销意图的边界，与当前登录账户的生命周期分离。
public protocol V2DeviceRevocationScheduling: Sendable {
    /// 保存撤销意图，成功返回代表已完成持久化交接，不代表远端撤销已经完成。
    func enqueue(_ intent: V2DeviceRevocationIntent) async throws
}

/// 撤销队列中的不可变任务快照，包含重试次数、下一次执行时间及可选暂停原因。
public struct V2DeviceRevocationJob: Codable, Equatable, Sendable {
    /// 需要显式恢复的暂停原因：凭证无效、操作身份冲突、请求无效或响应无效。
    public enum PauseReason: String, Codable, Sendable { case invalidCredential, operationConflict, invalidRequest, invalidResponse }
    /// 本任务稳定的撤销意图。
    public let intent: V2DeviceRevocationIntent
    /// 已记录的失败次数，递增到 UInt32 最大值后保持饱和。
    public let attempts: UInt32
    /// 未暂停时下一次允许调度的时间。
    public let nextAttemptAt: Date
    /// 非空时停止自动重试，等待显式恢复。
    public let pauseReason: PauseReason?
}

/// 供界面呈现的聚合状态：empty 表示无任务，paused 表示至少一项暂停，其余非空队列为 pending。
public enum V2DeviceRevocationQueueStatus: Equatable, Sendable { case empty, pending, paused }

/// 撤销队列的持久化与输入错误分类。
///
/// unavailable 表示存储暂时不可用；malformedRecord 表示账本损坏或不符合约束；capacityExceeded 表示达到容量上限；conflict 表示操作或设备身份冲突；invalidRequest 表示参数无效。
public enum V2DeviceRevocationStoreError: Error, Equatable, Sendable {
    case unavailable, malformedRecord, capacityExceeded, conflict, invalidRequest
    /// 未单独分类的 Keychain 状态码，不携带撤销凭证。
    case unexpectedStatus(Int32)
}

/// 单个凭证命名空间的撤销队列所有者，最多保存 256 项任务。
///
/// 每次修改同步替换一个 Keychain 项，保存成功后才通知观察者；不在此执行网络请求。
/// 相同 service 必须复用同一所有者，actor 隔离不提供多个实例之间的读改写互斥。
public actor V2DeviceRevocationStore: V2DeviceRevocationScheduling {
    /// 同步读写完整账本的底层持久化实现。
    private let persistence: any V2DeviceRevocationPersisting
    /// 包括暂停任务在内的持久化容量上限。
    private static let maximumJobs = 256
    /// 只接收保存后变更提示的调度观察者，不携带任务或凭证。
    private var observers: [UUID: AsyncThrowingStream<Void, any Error>.Continuation] = [:]

    /// 只接收聚合队列状态的展示观察者。
    private var statusObservers: [UUID: AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error>.Continuation] = [:]

    /// 创建使用系统 Keychain 的队列所有者，不立即读取账本。
    ///
    /// - Parameter service: Keychain 服务命名空间；同一命名空间应只创建一个所有者。
    public init(service: String) {
        persistence = V2KeychainDeviceRevocationPersistence(service: service)
    }

    /// 注入同步持久化边界，供隔离存储实现与测试使用。
    init(persistence: any V2DeviceRevocationPersisting) { self.persistence = persistence }

    /// 持久化撤销意图；完全相同的操作与内容重复提交时直接成功。
    ///
    /// - Parameter intent: 包含有限期限及稳定操作身份的撤销意图。
    /// - Throws: 日期非有限、相同操作内容不一致、同一用户设备已有其他任务、容量达到 256，或持久化失败。
    ///
    /// 新任务立即可调度，不因本地时钟判断凭证已过期而丢弃。
    public func enqueue(_ intent: V2DeviceRevocationIntent) throws {
        guard intent.expiresAt.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceRevocationStoreError.invalidRequest }
        var ledger = try load()
        let key = intent.operationID.uuidString
        if let existing = ledger.jobs[key] {
            guard existing.intent == intent else { throw V2DeviceRevocationStoreError.conflict }
            return
        }
        guard !ledger.jobs.values.contains(where: { $0.intent.userID == intent.userID && $0.intent.deviceID == intent.deviceID }) else {
            throw V2DeviceRevocationStoreError.conflict
        }
        guard ledger.jobs.count < Self.maximumJobs else { throw V2DeviceRevocationStoreError.capacityExceeded }
        ledger.jobs[key] = .init(intent: intent, attempts: 0, nextAttemptAt: .distantPast, pauseReason: nil)
        try save(ledger)
    }

    /// 将恢复意图与同一用户设备的既有撤销任务合并。
    ///
    /// 既有任务的撤销凭证与期限必须完全相同，允许沿用它的操作身份；否则抛出 conflict。
    /// 没有既有任务时按正常入队规则持久化。
    func enqueueRecovered(_ intent: V2DeviceRevocationIntent) throws {
        if let existing = try load().jobs.values.first(where: {
            $0.intent.userID == intent.userID && $0.intent.deviceID == intent.deviceID
        }) {
            guard existing.intent.credential == intent.credential, existing.intent.expiresAt == intent.expiresAt else {
                throw V2DeviceRevocationStoreError.conflict
            }
            return
        }
        try enqueue(intent)
    }

    /// 读取经过校验的全部任务，按操作 UUID 字符串排序。
    ///
    /// - Returns: 包括暂停和未到期任务的快照；顺序不代表创建时间。
    /// - Throws: 存储不可用或账本校验错误。
    public func jobs() throws -> [V2DeviceRevocationJob] {
        try load().jobs.values.sorted { $0.intent.operationID.uuidString < $1.intent.operationID.uuidString }
    }

    /// 选择未暂停且已到重试时间的任务，按重试时间及操作身份稳定排序。
    ///
    /// - Parameters:
    ///   - now: 有限的调度时钟值。
    ///   - limit: 返回上限，默认 4，允许 1 到 32。
    /// - Returns: 最多 limit 项到期快照。
    /// - Throws: 参数无效或账本读取失败。
    ///
    /// 本地期限已过不等于服务端已确认失效，不能据此完成撤销任务。
    public func due(at now: Date, limit: Int = 4) throws -> [V2DeviceRevocationJob] {
        guard now.timeIntervalSinceReferenceDate.isFinite, (1...32).contains(limit) else { throw V2DeviceRevocationStoreError.invalidRequest }
        // A local clock is not proof of server expiry. Only a server result
        // can settle an intent; an expired local deadline remains retryable.
        return Array(try load().jobs.values.filter { $0.pauseReason == nil && $0.nextAttemptAt <= now }.sorted {
            if $0.nextAttemptAt != $1.nextAttemptAt { return $0.nextAttemptAt < $1.nextAttemptAt }
            return $0.intent.operationID.uuidString < $1.intent.operationID.uuidString
        }.prefix(limit))
    }

    /// 仅当持久化任务仍等于输入快照时记录失败，避免迟到请求覆盖更新后的任务。
    ///
    /// - Parameters:
    ///   - job: 请求开始前读取的任务快照。
    ///   - retryAt: 有限的下一次尝试时间。
    ///   - pauseReason: 非空时暂停自动重试。
    /// - Returns: 更新成功为 true；任务不存在或已变化为 false。
    /// - Throws: 任务取消、日期无效或持久化错误。
    ///
    /// 失败次数采用饱和递增，不会溢出回零。
    @discardableResult
    public func recordFailure(_ job: V2DeviceRevocationJob, retryAt: Date,
        pauseReason: V2DeviceRevocationJob.PauseReason? = nil) throws -> Bool {
        try Task.checkCancellation()
        guard retryAt.timeIntervalSinceReferenceDate.isFinite else { throw V2DeviceRevocationStoreError.invalidRequest }
        var ledger = try load()
        let key = job.intent.operationID.uuidString
        guard ledger.jobs[key] == job else { return false }
        ledger.jobs[key] = .init(intent: job.intent, attempts: job.attempts == .max ? .max : job.attempts + 1,
            nextAttemptAt: retryAt, pauseReason: pauseReason)
        try save(ledger)
        return true
    }

    /// 仅当任务仍等于请求前快照时删除并持久化完成结果。
    ///
    /// - Parameter job: 已获得服务端完成结果的任务快照。
    /// - Returns: 删除成功为 true；任务不存在或已变化为 false。
    /// - Throws: 任务取消或持久化错误；不会仅凭本地期限完成任务。
    @discardableResult
    public func complete(_ job: V2DeviceRevocationJob) throws -> Bool {
        try Task.checkCancellation()
        var ledger = try load()
        let key = job.intent.operationID.uuidString
        guard ledger.jobs[key] == job else { return false }
        ledger.jobs[key] = nil
        try save(ledger)
        return true
    }

    /// 响应用户显式恢复意图，将所有暂停任务改为立即可执行。
    ///
    /// 保留撤销证明、操作身份和尝试次数，普通退避任务不变；没有暂停任务时不写存储。
    /// - Throws: 任务取消或持久化错误。
    public func retryPaused() throws {
        try Task.checkCancellation()
        var ledger = try load()
        var changed = false
        for (key, job) in ledger.jobs where job.pauseReason != nil {
            ledger.jobs[key] = .init(intent: job.intent, attempts: job.attempts,
                nextAttemptAt: .distantPast, pauseReason: nil)
            changed = true
        }
        if changed { try save(ledger) }
    }

    /// 订阅聚合状态，在同一 actor 执行段中完成初始读取与观察者注册。
    ///
    /// - Returns: 立即发送初始快照、只缓冲最新状态的流；读取失败时以错误结束。
    ///
    /// 流不包含凭证或具体任务。任一任务暂停时整体为 paused，队列中仍可能有可执行任务。
    public func statusUpdates() -> AsyncThrowingStream<V2DeviceRevocationQueueStatus, any Error> {
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

    /// 移除已结束的聚合状态订阅，不改变队列任务。
    private func removeStatusObserver(_ id: UUID) { statusObservers[id] = nil }
    /// 从账本生成聚合状态；任一暂停任务优先于普通待处理状态。
    private func status(_ ledger: Ledger) -> V2DeviceRevocationQueueStatus {
        if ledger.jobs.isEmpty { return .empty }
        return ledger.jobs.values.contains { $0.pauseReason != nil } ? .paused : .pending
    }

    /// 提供未暂停任务的最早执行时间及保存后的唤醒流，供命令重试调度器使用。
    func retrySchedule() -> V2CommandRetrySchedule {
        .init(nextAttemptAt: { try await self.jobs().filter { $0.pauseReason == nil }.map(\.nextAttemptAt).min() },
            updates: { await self.updates() })
    }

    /// 注册只缓冲最新一项的变更提示流，不发送初始提示；调度器另行读取最早执行时间。
    private func updates() -> AsyncThrowingStream<Void, any Error> {
        let id = UUID()
        let stream = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream.stream
    }

    /// 移除已结束的调度订阅。
    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// 读取并校验版本为 1 的完整账本，不存在时返回空账本。
    ///
    /// 检查容量、字典键与操作身份一致性、有限日期，以及用户设备组合唯一性；失败报告 malformedRecord。
    /// 不会自动丢弃损坏任务或按本地期限清理凭证。
    private func load() throws -> Ledger {
        guard let data = try persistence.load() else { return .init() }
        guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 1,
              ledger.jobs.count <= Self.maximumJobs,
              ledger.jobs.allSatisfy({ key, job in
                  key == job.intent.operationID.uuidString && job.intent.expiresAt.timeIntervalSinceReferenceDate.isFinite &&
                      job.nextAttemptAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw V2DeviceRevocationStoreError.malformedRecord }
        let targets = ledger.jobs.values.map { Target(userID: $0.intent.userID, deviceID: $0.intent.deviceID) }
        guard Set(targets).count == targets.count else { throw V2DeviceRevocationStoreError.malformedRecord }
        return ledger
    }

    /// 将完整账本编码后保存，空账本删除存储项；仅在持久化成功后唤醒调度并广播聚合状态。
    private func save(_ ledger: Ledger) throws {
        if ledger.jobs.isEmpty { try persistence.delete() }
        else { try persistence.save(JSONEncoder().encode(ledger)) }
        for observer in observers.values { observer.yield(()) }
        let snapshot = status(ledger)
        for observer in statusObservers.values { observer.yield(snapshot) }
    }

    /// 账本校验时用于检测重复用户设备组合的键。
    private struct Target: Hashable { let userID: UserID; let deviceID: DeviceID }
    /// 版本化的完整队列存储格式，任务以操作 UUID 字符串为键。
    private struct Ledger: Codable { var version = 1; var jobs: [String: V2DeviceRevocationJob] = [:] }
}

/// 同步替换完整队列数据的持久化边界，调用期间不得拆分账本写入。
protocol V2DeviceRevocationPersisting: Sendable {
    /// 读取完整账本字节，不存在时返回 nil，访问失败时抛出错误。
    func load() throws -> Data?
    /// 同步保存完整账本字节，失败时通过错误报告。
    func save(_ data: Data) throws
    /// 删除账本存储项，缺失项应视为已删除。
    func delete() throws
}

/// 在单个通用密码项中保存撤销账本的 Keychain 适配器。
///
/// 使用首次解锁后可访问且仅限当前设备的保护级别，支持延迟退出清理；不支持 Security 的平台明确报告存储不可用。
private struct V2KeychainDeviceRevocationPersistence: V2DeviceRevocationPersisting {
    /// 隔离撤销账本的 Keychain 服务名。
    let service: String
#if canImport(Security)
    /// 以服务名及固定账户 device-revocation-outbox-v1 定位通用密码项。
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "device-revocation-outbox-v1"]
    }
    /// 读取唯一匹配项并要求结果为 Data；缺失返回 nil，状态错误或类型错误明确抛出。
    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2DeviceRevocationStoreError.malformedRecord }
        return data
    }
    /// 先更新既有项，仅在不存在时插入；同时设置设备限定的首次解锁后保护级别。
    func save(_ data: Data) throws {
        // This item contains only revocation authority, never login authority.
        // Device-only availability after first unlock permits deferred cleanup.
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        let inserted = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw error(inserted) }
    }
    /// 删除匹配项，将不存在视为成功，其余系统错误映射为存储错误。
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    /// 将不可访问状态映射为 unavailable、解码错误映射为 malformedRecord，其余保留原始状态码。
    private func error(_ status: OSStatus) -> V2DeviceRevocationStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        default: .unexpectedStatus(status)
        }
    }
#else
    func load() throws -> Data? { throw V2DeviceRevocationStoreError.unavailable }
    func save(_: Data) throws { throw V2DeviceRevocationStoreError.unavailable }
    func delete() throws { throw V2DeviceRevocationStoreError.unavailable }
#endif
}
