import Crypto
import Foundation
import IMV2Core

/// store 身份验证失败。
public enum V2AccountLocalStoreError: Error, Equatable, Sendable {
    case staleStore
}

/// 会话 bootstrapper 拥有的账号数据库管理器。
///
/// 普通关闭保留目录与 outbox；显式擦除属于另一条流程。使用任务尾链把跨 await 的
/// 打开／关闭串行化，并按具体 store 对象定位关闭目标，避免旧账号的迟到 close
/// 关闭后来创建的实例。调用者需在关闭前停止该 store 的业务访问者。
public actor V2AccountLocalStoreOwner {
    private let root: URL
    private let cacheRoot: URL
    private let bootstrapper: V2LocalStoreBootstrapper
    private var catalogs: [UserID: V2AccountStorageDirectory] = [:]
    private var current: (scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore, readOnly: Bool)?
    private var tail: (id: UUID, task: Task<Void, Never>)?
    private var rootPrepared = false

    /// 指定账号目录根与安装绑定验证器。
    ///
    /// - Parameters:
    ///   - root: 按账号散列和目录实例组织数据的受管根。
    ///   - bootstrapper: 打开数据库前验证设备安装绑定的依赖。
    ///
    /// 构造不触碰文件系统；目录根在首次实际打开时创建。
    public init(root: URL, cacheRoot: URL, bootstrapper: V2LocalStoreBootstrapper) {
        self.root = root
        self.cacheRoot = cacheRoot
        self.bootstrapper = bootstrapper
    }

    /// 串行打开账号存储，同一当前账号复用已有 store。
    ///
    /// 切换账号时先关闭当前 store，再打开目标目录。
    /// 取消等待者不会自动撤销已经排队的内部状态转换；认证代次由上层另行检查。
    ///
    /// - Parameter accountID: 已认证账号的领域身份。
    /// - Returns: 通过安装绑定检查、属于目标账号的本地 store。
    /// - Throws: 原 store 关闭、目录或数据库 bootstrap 错误。
    public func open(accountID: UserID) async throws -> GRDBV2LocalSyncStore {
        try await serialize { try await self.performOpen(accountID: accountID) }
    }

    /// 只定位既有目录，保留所有打开／关闭和清理责任。
    public func existingScopeForLocalRead(accountID: UserID) async throws -> V2AccountStorageScope {
        try await serialize { try await self.catalog(for: accountID).existingScopeForLocalRead(accountID: accountID) }
    }

    func openLocalReadOnly(_ permit: V2OfflineReadBootstrap) async throws -> GRDBV2LocalSyncStore {
        try await serialize { try await self.performOpenLocalReadOnly(permit) }
    }
    private func performOpenLocalReadOnly(_ permit: V2OfflineReadBootstrap) async throws -> GRDBV2LocalSyncStore {
        guard let scope = permit.storageScope,
              try await catalog(for: permit.identity.userID).existingScopeForLocalRead(accountID: permit.identity.userID) == scope else {
            throw V2OfflineReadBootstrapError.localStoreUnavailable
        }
        if let current, current.scope == scope, current.readOnly { return current.store }
        if let current { try await current.store.close(); self.current = nil }
        let store = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: permit.databaseURL,
            installationBinding: permit.installationBinding, userID: permit.identity.userID)
        current = (scope, store, true)
        return store
    }

    /// 查询当前 store 对象的目录实例。
    ///
    /// - Parameter store: 必须与本管理器当前持有的对象相同，而非仅账号相同。
    /// - Returns: 与该对象绑定的账号 scope。
    /// - Throws: 对象已替换或不是当前对象时抛出 staleStore。
    public func scope(for store: GRDBV2LocalSyncStore) throws -> V2AccountStorageScope {
        guard let current, current.store === store else { throw V2AccountLocalStoreError.staleStore }
        return current.scope
    }

    /// 串行关闭捕获的 store 对象，不擦除其数据库和 outbox。
    ///
    /// 即使对象已不是 current，也只关闭传入对象；只有仍为 current 时才清空当前引用。
    ///
    /// - Parameter store: 业务访问者已经停止使用的原 store 对象。
    /// - Throws: 数据库关闭错误；失败不表示目录已擦除。
    public func close(_ store: GRDBV2LocalSyncStore) async throws {
        try await serialize {
            // Close that captured object even if it is no longer current.
            // Never look up the deletion/close target by current account name.
            try await store.close()
            await self.forgetIfCurrent(store)
        }
    }

    private func forgetIfCurrent(_ store: GRDBV2LocalSyncStore) {
        if current?.store === store { current = nil }
    }

    /// 把异步状态转换接到前一个操作之后，防止 actor 重入造成打开／关闭交错。
    ///
    /// 内部任务持有执行责任；调用者取消不传播为中途取消迁移。tail 仅在身份仍匹配时清除。
    private func serialize<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail?.task
        let id = UUID()
        let operation = Task { await previous?.value; return try await work() }
        tail = (id, Task { _ = await operation.result })
        defer { if tail?.id == id { tail = nil } }
        return try await operation.value
    }

    /// 按账号原始值的 SHA-256 散列定位目录管理器，避免把领域 ID 直接解释为路径片段。
    private func catalog(for accountID: UserID) -> V2AccountStorageDirectory {
        if let existing = catalogs[accountID] { return existing }
        // UserID is a domain identifier, not a filesystem path component.
        let key = SHA256.hash(data: Data(accountID.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let catalog = V2AccountStorageDirectory(root: root.appending(path: key, directoryHint: .isDirectory),
                                              cacheRoot: cacheRoot.appending(path: key, directoryHint: .isDirectory))
        catalogs[accountID] = catalog
        return catalog
    }

    private func performOpen(accountID: UserID) async throws -> GRDBV2LocalSyncStore {
        if let current, current.scope.accountID == accountID, !current.readOnly { return current.store }
        if let current { try await current.store.close(); self.current = nil }
        try prepareRootIfNeeded()
        let scope = try await catalog(for: accountID).openScope(accountID: accountID)
        let store = try await bootstrapper.open(databaseURL: scope.database.primary, userID: accountID)
        current = (scope, store, false)
        return store
    }

    /// 首次打开前创建受管目录根并排除设备备份。
    private func prepareRootIfNeeded() throws {
        guard !rootPrepared else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: root)
        rootPrepared = true
    }
}
