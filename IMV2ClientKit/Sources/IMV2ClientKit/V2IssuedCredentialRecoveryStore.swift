import Foundation
#if canImport(Security)
import Security
#endif

/// 在登录所有者接纳新签发凭证之前，持久化其可恢复的撤销权限。
///
/// 存储只包含撤销能力，不保存访问或刷新凭证。调用者应先记录接收，再完成会话接纳，最后确认收据；不能接纳时交给撤销流程。
public protocol V2IssuedCredentialRecovering: Sendable {
    /// 持久化签发凭证的撤销能力并返回收据，成功不表示已建立登录。
    func receive(_ credentials: V2AuthCredentials, operationID: UUID) async throws -> V2DeviceRevocationIntent
    /// 在调用方持久化接纳凭证后确认收据，不替代认证会话保存。
    func adopt(_ receipt: V2DeviceRevocationIntent) async throws
    /// 持久化放弃意图并交接撤销队列，失败应保留可重试的恢复信息。
    func abandon(_ receipt: V2DeviceRevocationIntent) async throws
}

/// 签发凭证恢复账本的错误分类。
///
/// unavailable 表示暂时不可访问；malformedRecord 表示账本格式或约束无效；conflict 表示收据身份或处理阶段不匹配；capacityExceeded 表示达到 256 条容量上限。
public enum V2IssuedCredentialRecoveryError: Error, Equatable, Sendable {
    case unavailable, malformedRecord, conflict, capacityExceeded
    /// 未分类的 Keychain 状态码，不附带凭证数据。
    case unexpectedStatus(Int32)
}

/// 保存签发后尚未确认归属的撤销收据，并将放弃的收据交接给持久化撤销队列。
///
/// 确认接纳会删除收据；放弃会先保存 abandoned，再入队撤销，入队成功后才删除恢复记录。
/// 同一服务命名空间应使用单个实例，actor 隔离不协调多个实例对同一账本的读改写。
public actor V2IssuedCredentialRecoveryStore: V2IssuedCredentialRecovering {
    /// 同步读写完整恢复账本的底层存储。
    private let persistence: any V2IssuedCredentialRecoveryPersisting
    /// 接收未被账户接纳的设备会话撤销任务的独立队列。
    private let revocations: V2DeviceRevocationStore

    /// 配置 Keychain 恢复账本及撤销队列，不立即执行恢复。
    ///
    /// - Parameters:
    ///   - service: 恢复账本的 Keychain 服务命名空间。
    ///   - revocations: 同一应用生命周期拥有的撤销队列。
    public init(service: String, revocations: V2DeviceRevocationStore) {
        persistence = V2KeychainIssuedCredentialRecoveryPersistence(service: service)
        self.revocations = revocations
    }

    /// 注入同步恢复账本存储及撤销队列，供隔离持久化实现或测试使用。
    init(persistence: any V2IssuedCredentialRecoveryPersisting, revocations: V2DeviceRevocationStore) {
        self.persistence = persistence; self.revocations = revocations
    }

    /// 从已签发凭证提取撤销收据并保存为 awaitingAdoption。
    ///
    /// - Parameters:
    ///   - credentials: 注册边界返回的完整凭证，只提取撤销所需字段。
    ///   - operationID: 本次接收使用的稳定操作身份。
    /// - Returns: 已持久化的撤销收据；相同身份与内容且仍待接纳时返回相同收据。
    /// - Throws: 已有操作内容或阶段冲突、容量达到 256，或存储失败。
    ///
    /// 不验证服务端签发、不建立登录，也不保存访问或刷新令牌。
    public func receive(_ credentials: V2AuthCredentials, operationID: UUID) throws -> V2DeviceRevocationIntent {
        let intent = V2DeviceRevocationIntent(credentials: credentials, operationID: operationID)
        var ledger = try load()
        let key = operationID.uuidString
        if let existing = ledger.records[key] {
            guard existing.intent == intent, existing.disposition == .awaitingAdoption else { throw V2IssuedCredentialRecoveryError.conflict }
            return intent
        }
        guard ledger.records.count < 256 else { throw V2IssuedCredentialRecoveryError.capacityExceeded }
        ledger.records[key] = .init(intent: intent, disposition: .awaitingAdoption)
        try save(ledger)
        return intent
    }

    /// 确认调用方已接纳凭证，删除完全匹配且仍处于 awaitingAdoption 的恢复收据。
    ///
    /// - Parameter receipt: 接收阶段返回的完整收据。
    /// - Throws: 记录缺失、内容不匹配或已经放弃时抛出 conflict；存储失败保留错误。
    ///
    /// 本方法不替调用方保存认证凭证，应在会话持久化成功后调用；重复确认缺失收据并非幂等成功。
    public func adopt(_ receipt: V2DeviceRevocationIntent) throws {
        var ledger = try load()
        guard let existing = ledger.records[receipt.operationID.uuidString] else { throw V2IssuedCredentialRecoveryError.conflict }
        guard existing.intent == receipt, existing.disposition == .awaitingAdoption else { throw V2IssuedCredentialRecoveryError.conflict }
        ledger.records[receipt.operationID.uuidString] = nil
        try save(ledger)
    }

    /// 先将匹配收据持久化为 abandoned，再尝试交接全部已放弃收据。
    ///
    /// - Parameter receipt: 无法接纳的签发凭证收据。
    /// - Throws: 内容冲突、恢复账本或撤销队列错误。
    ///
    /// 收据已不存在时直接返回；失败后已保存的放弃意图仍可在后续恢复中继续交接。
    public func abandon(_ receipt: V2DeviceRevocationIntent) async throws {
        var ledger = try load()
        guard let existing = ledger.records[receipt.operationID.uuidString] else { return }
        guard existing.intent == receipt else { throw V2IssuedCredentialRecoveryError.conflict }
        if existing.disposition != .abandoned {
            ledger.records[receipt.operationID.uuidString] = .init(intent: receipt, disposition: .abandoned)
            try save(ledger)
        }
        try await drainAbandoned()
    }

    /// 冷启动时根据持久化认证记录判断待接纳收据归属，并交接其余收据。
    ///
    /// - Parameter record: 启动阶段读取的认证记录；仅无待撤销标识且用户、设备、撤销凭证和期限完全匹配时视为已接纳。
    /// - Throws: 恢复账本读写或撤销交接错误。
    ///
    /// 必须在允许交互式注册前运行，不能与本进程正在进行的注册并用，否则尚待接纳的有效结果可能被判断为放弃。
    /// 不以访问令牌是否相同判断归属，以允许同一会话已发生凭证轮换。
    public func recoverUnclaimed(ownedBy record: V2AuthCredentialRecord?) async throws {
        var ledger = try load()
        var changed = false
        for (key, entry) in ledger.records where entry.disposition == .awaitingAdoption {
            let credentials = record?.credentials
            let adopted = record?.pendingRevocationOperationID == nil &&
                credentials?.userID == entry.intent.userID && credentials?.deviceID == entry.intent.deviceID &&
                credentials?.revocationCredential == entry.intent.credential &&
                credentials?.revocationCredentialExpiresAt == entry.intent.expiresAt
            if adopted { ledger.records[key] = nil }
            else { ledger.records[key] = .init(intent: entry.intent, disposition: .abandoned) }
            changed = true
        }
        if changed { try save(ledger) }
        try await drainAbandoned()
    }

    /// 读取已放弃收据快照，逐项交接撤销队列后重新读取账本并条件删除。
    ///
    /// 相同设备会话已有撤销任务时沿用其操作身份、尝试次数和暂停状态。挂起期间记录变化则跳过删除，避免覆盖后续状态。
    /// - Throws: 任一队列或账本操作失败，当前及剩余未删除收据保留供重试。
    ///
    /// 本方法只完成本地持久化交接，不等待远端撤销请求。
    public func drainAbandoned() async throws {
        let abandoned = try load().records.values.filter { $0.disposition == .abandoned }
        for entry in abandoned {
            // The queue may already contain a logout for the same session.
            // Preserve its operation, retry count and pause state in that case.
            try await revocations.enqueueRecovered(entry.intent)
            var ledger = try load()
            let key = entry.intent.operationID.uuidString
            guard ledger.records[key] == entry else { continue }
            ledger.records[key] = nil
            try save(ledger)
        }
    }

    /// 读取版本 1 的完整账本，不存在时返回空账本。
    ///
    /// 校验最多 256 条记录、字典键与操作身份一致以及期限有限；解码或约束失败报告 malformedRecord，不静默丢弃记录。
    private func load() throws -> Ledger {
        guard let data = try persistence.load() else { return .init() }
        guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data), ledger.version == 1,
              ledger.records.count <= 256,
              ledger.records.allSatisfy({ key, record in
                  key == record.intent.operationID.uuidString && record.intent.expiresAt.timeIntervalSinceReferenceDate.isFinite
              }) else { throw V2IssuedCredentialRecoveryError.malformedRecord }
        return ledger
    }
    /// 保存完整 JSON 账本，空账本删除存储项；失败直接传播，不执行网络请求。
    private func save(_ ledger: Ledger) throws {
        if ledger.records.isEmpty { try persistence.delete() }
        else { try persistence.save(JSONEncoder().encode(ledger)) }
    }
    /// 收据处理阶段：awaitingAdoption 等待账户接纳，abandoned 等待撤销交接。
    private enum Disposition: String, Codable { case awaitingAdoption, abandoned }
    /// 完整恢复记录，由稳定撤销意图及当前处理阶段组成。
    private struct Record: Codable, Equatable { let intent: V2DeviceRevocationIntent; let disposition: Disposition }
    /// 版本化恢复账本，以操作 UUID 字符串索引记录。
    private struct Ledger: Codable { var version = 1; var records: [String: Record] = [:] }
}

/// 同步读取、替换及删除完整恢复账本的持久化边界。
protocol V2IssuedCredentialRecoveryPersisting: Sendable {
    /// 返回完整账本字节，不存在时返回 nil，读取失败抛出错误。
    func load() throws -> Data?
    /// 同步替换完整账本字节，成功返回才表示保存完成。
    func save(_ data: Data) throws
    /// 删除账本项，不存在应视为成功。
    func delete() throws
}

/// 使用单个 Keychain 通用密码项保存恢复账本。
///
/// 存储项仅含撤销能力，使用设备限定的首次解锁后保护级别；不支持 Security 的平台明确报告 unavailable。
private struct V2KeychainIssuedCredentialRecoveryPersistence: V2IssuedCredentialRecoveryPersisting {
    /// 恢复账本所属的 Keychain 服务名。
    let service: String
#if canImport(Security)
    /// 以服务名及固定账户 received-device-credentials-v1 定位恢复账本。
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "received-device-credentials-v1"]
    }
    /// 读取唯一匹配项目并要求结果为 Data，不存在返回 nil，类型或系统错误明确抛出。
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw error(status) }
        guard let data = value as? Data else { throw V2IssuedCredentialRecoveryError.malformedRecord }
        return data
    }
    /// 先更新既有项目，仅在不存在时插入，同时设置设备限定的首次解锁后保护级别。
    func save(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw error(status) }
        let added = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        guard added == errSecSuccess else { throw error(added) }
    }
    /// 删除匹配项，不存在视为成功，其他系统错误按恢复存储错误映射。
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    /// 将 Keychain 不可访问状态映射为 unavailable，解码失败映射为 malformedRecord，其余保留状态码。
    private func error(_ status: OSStatus) -> V2IssuedCredentialRecoveryError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .unavailable
        case errSecDecode: .malformedRecord
        default: .unexpectedStatus(status)
        }
    }
#else
    /// 当前平台没有 Security 支持，始终抛出 unavailable。
    func load() throws -> Data? { throw V2IssuedCredentialRecoveryError.unavailable }
    /// 当前平台没有 Security 支持，不保存输入并抛出 unavailable。
    func save(_: Data) throws { throw V2IssuedCredentialRecoveryError.unavailable }
    /// 当前平台没有 Security 支持，始终抛出 unavailable。
    func delete() throws { throw V2IssuedCredentialRecoveryError.unavailable }
#endif
}
