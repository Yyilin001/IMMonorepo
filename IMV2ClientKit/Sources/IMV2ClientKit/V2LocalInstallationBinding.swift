import Foundation
import IMV2Core

/// 非秘密的本地存储绑定标记，同时记录于设备限定 Keychain 与 V2 SQLite 数据库。
///
/// 打开数据库时由引导层比较标记，识别缺少匹配绑定的数据库；该 UUID 本身不是账户认证凭证。
public struct V2LocalInstallationBinding: Codable, Equatable, Sendable {
    /// 用于比较 Keychain 与数据库归属的 UUID。
    public let value: UUID

    /// 包装调用方提供的绑定 UUID，不访问 Keychain 或数据库。
    public init(value: UUID) { self.value = value }
}

/// 安装绑定存储的访问、格式与失效错误分类。
public enum V2InstallationBindingStoreError: Error, Equatable, Sendable {
    /// 绑定项当前不可访问，不能据此推断数据库来自其他设备。
    case unavailable
    /// 绑定记录类型或编码格式无效。
    case malformedRecord
    /// 绑定项已被底层分类为永久失效。
    case permanentlyInvalidated
    /// 未分类的 Keychain 状态码。
    case unexpectedStatus(Int32)
}

/// 独立于账户令牌轮换的本地数据库绑定存储边界。
public protocol V2InstallationBindingStore: Sendable {
    /// 读取绑定标记，不存在返回 nil；暂时不可用必须通过错误区分。
    func load() async throws -> V2LocalInstallationBinding?
    /// 保存完整绑定标记，不与访问或刷新凭证混合存储。
    func save(_ binding: V2LocalInstallationBinding) async throws
    /// 删除绑定标记，调用方负责协调受该绑定保护的数据库生命周期。
    func delete() async throws
}


/// 本地存储引导错误，installationBindingUnavailable 表示无法取得可靠绑定状态。
public enum V2LocalStoreBootstrapError: Error, Equatable, Sendable {
    /// 安装绑定暂时不可读取，不能继续判断数据库归属。
    case installationBindingUnavailable
}

/// 根据设备限定绑定决定保留或重建 V2 本地数据库的生产入口。
///
/// Keychain 暂时不可用不作为数据库导入证据；缺失、明确失效或不匹配的绑定按对应恢复路径处理。
/// actor 方法内部有异步存储调用，调用方仍需协调同一数据库的打开生命周期，不能仅依赖 actor 获得跨挂起的整体互斥。
public actor V2LocalStoreBootstrapper {
    /// 独立保存本地数据库绑定标记的持久化边界。
    private let bindingStore: any V2InstallationBindingStore
    /// 需要重建绑定时生成新标记的可注入工厂。
    private let makeBinding: @Sendable () -> V2LocalInstallationBinding

    /// 注入绑定存储及新标记工厂，不立即打开数据库。
    ///
    /// - Parameters:
    ///   - bindingStore: 保存设备限定绑定的存储。
    ///   - makeBinding: 需要新绑定时调用，默认生成随机 UUID。
    public init(
        bindingStore: any V2InstallationBindingStore,
        makeBinding: @escaping @Sendable () -> V2LocalInstallationBinding = { .init(value: UUID()) }
    ) {
        self.bindingStore = bindingStore
        self.makeBinding = makeBinding
    }

    func bindingStoreForLocalRead() async throws -> V2LocalInstallationBinding? { try await bindingStore.load() }

    /// 取得安装绑定并打开账户本地数据库，缺失或不匹配时按约定重建。
    ///
    /// - Parameters:
    ///   - databaseURL: 要打开的 V2 数据库位置，恢复清理前相关数据库文件必须已关闭。
    ///   - userID: 可选账户归属，交给本地存储构造器校验。
    /// - Returns: 带匹配安装绑定的本地同步存储。
    /// - Throws: 绑定暂时不可用、文件清理、存储访问或数据库初始化错误。
    ///
    /// 无绑定时先清理数据库文件再保存新标记；损坏或永久失效时先删除绑定再重建。
    /// 数据库绑定不匹配时使用同一设备标记清理重开一次，第二次失败直接传播，不无限重建。
    public func open(databaseURL: URL, userID: UserID? = nil, storageScope: V2AccountStorageScope? = nil) async throws -> GRDBV2LocalSyncStore {
        if let storageScope {
            guard storageScope.accountID == userID, storageScope.database.primary.standardizedFileURL == databaseURL.standardizedFileURL
            else { throw V2AccountStorageError.scopeMismatch }
        }
        var binding: V2LocalInstallationBinding
        do {
            if let existing = try await bindingStore.load() {
                binding = existing
            } else {
                // A database with no device-only anchor is untrusted. Remove
                // only the exact V2 artifacts, then establish a fresh anchor.
                try eraseDatabaseArtifacts(at: databaseURL)
                binding = makeBinding()
                try await bindingStore.save(binding)
            }
        } catch let error as V2InstallationBindingStoreError {
            switch error {
            case .unavailable, .unexpectedStatus:
                throw V2LocalStoreBootstrapError.installationBindingUnavailable
            case .malformedRecord, .permanentlyInvalidated:
                // A permanently unusable device-only anchor cannot establish
                // trust in an existing database. Remove it only after the
                // Keychain boundary has made this terminal classification.
                try await bindingStore.delete()
                try eraseDatabaseArtifacts(at: databaseURL)
                binding = makeBinding()
                try await bindingStore.save(binding)
            }
        }

        do {
            return try GRDBV2LocalSyncStore(databaseURL: databaseURL, installationBinding: binding, userID: userID, storageScope: storageScope)
        } catch V2ClientLocalStorageError.installationBindingMismatch {
            // Existing device anchor plus a non-matching database is an import
            // or restore, not a migratable cache. Recreate once with the same
            // device anchor; a second failure is surfaced to the caller.
            try eraseDatabaseArtifacts(at: databaseURL)
            return try GRDBV2LocalSyncStore(databaseURL: databaseURL, installationBinding: binding, userID: userID, storageScope: storageScope)
        }
    }

    /// 通过 V2LocalDatabaseArtifacts 清理指定数据库的已关闭文件，传播文件错误，不在此关闭活跃连接。
    private func eraseDatabaseArtifacts(at databaseURL: URL) throws {
        try V2LocalDatabaseArtifacts(primary: databaseURL).removeClosedFiles()
    }
}
