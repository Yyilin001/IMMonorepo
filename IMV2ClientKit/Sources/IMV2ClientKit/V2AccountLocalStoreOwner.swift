import Crypto
import Foundation
import IMV2Core

/// 账号存储归属、旧库迁移或 store 身份验证失败。
public enum V2AccountLocalStoreError: Error, Equatable, Sendable {
    case unattributedLegacyStore, migrationConflict, staleStore
}

/// 会话 bootstrapper 拥有的账号数据库管理器。
///
/// 普通关闭保留目录与 outbox；显式擦除属于另一条流程。使用任务尾链把跨 await 的
/// 打开／关闭串行化，并按具体 store 对象定位关闭目标，避免旧账号的迟到 close
/// 关闭后来创建的实例。调用者需在关闭前停止该 store 的业务访问者。
public actor V2AccountLocalStoreOwner {
    private struct Migration: Codable {
        let version: Int
        let accountID: String
        let incarnation: UUID
    }
    private let root: URL
    private let legacy: V2LocalDatabaseArtifacts
    private let bootstrapper: V2LocalStoreBootstrapper
    private var catalogs: [UserID: V2AccountStorageDirectory] = [:]
    private var current: (scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore)?
    private var tail: (id: UUID, task: Task<Void, Never>)?
    private var migrationFinished = false

    /// 指定账号目录根、旧库位置与安装绑定验证器。
    ///
    /// - Parameters:
    ///   - root: 按账号散列和目录实例组织新数据的受管根。
    ///   - legacyDatabaseURL: 待验证归属并迁移的旧主库位置。
    ///   - bootstrapper: 打开数据库前验证设备安装绑定的依赖。
    ///
    /// 构造不迁移文件；迁移在首次实际打开时执行。
    public init(root: URL, legacyDatabaseURL: URL, bootstrapper: V2LocalStoreBootstrapper) {
        self.root = root
        legacy = .init(primary: legacyDatabaseURL)
        self.bootstrapper = bootstrapper
    }

    /// 串行打开账号存储，同一当前账号复用已有 store。
    ///
    /// 切换账号时先关闭当前 store，再处理旧库迁移并打开目标目录。
    /// 取消等待者不会自动撤销已经排队的内部状态转换；认证代次由上层另行检查。
    ///
    /// - Parameter accountID: 已认证账号的领域身份。
    /// - Returns: 通过安装绑定检查、属于目标账号的本地 store。
    /// - Throws: 原 store 关闭、目录、旧库迁移或数据库 bootstrap 错误。
    public func open(accountID: UserID) async throws -> GRDBV2LocalSyncStore {
        try await serialize { try await self.performOpen(accountID: accountID) }
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
        let catalog = V2AccountStorageDirectory(root: root.appending(path: key, directoryHint: .isDirectory))
        catalogs[accountID] = catalog
        return catalog
    }

    private func performOpen(accountID: UserID) async throws -> GRDBV2LocalSyncStore {
        if let current, current.scope.accountID == accountID { return current.store }
        if let current { try await current.store.close(); self.current = nil }
        try await migrateLegacyIfNeeded()
        let scope = try await catalog(for: accountID).openScope(accountID: accountID)
        let store = try await bootstrapper.open(databaseURL: scope.database.primary, userID: accountID)
        current = (scope, store)
        return store
    }

    private var migrationURL: URL { root.appending(path: "legacy-import.json") }

    /// 验证旧库安装与账号归属，再按持久迁移记录移动主库工件。
    ///
    /// 先写入 migration 标记，再逐个原子 rename，以便重启完成任意前缀。
    /// 旧搜索库不导入新账号范围，而是在受信主库要求重建后清理。
    /// 任何目标冲突都停止迁移，不覆盖现存新库，也不把未知旧账号改绑为当前登录账号。
    private func migrateLegacyIfNeeded() async throws {
        guard !migrationFinished else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: root)
        let migration: Migration
        if fm.fileExists(atPath: migrationURL.path) {
            migration = try JSONDecoder().decode(Migration.self, from: Data(contentsOf: migrationURL))
            guard migration.version == 1 else { throw V2AccountStorageError.invalidManifest }
        } else if fm.fileExists(atPath: legacy.primary.path) {
            // Validate the installation before reading an account identity.
            // Passing no user never relabels an existing account as the login.
            guard let old = try await bootstrapper.openTrustedLegacyStore(databaseURL: legacy.primary) else {
                migrationFinished = true
                return
            }
            let storedAccount: UserID?
            do {
                storedAccount = try await old.boundAccountID()
                if storedAccount != nil { try await old.requireMessageSearchIndexRebuild() }
            }
            catch { try await old.close(); throw error }
            try await old.close()
            guard let account = storedAccount else { throw V2AccountLocalStoreError.unattributedLegacyStore }
            let scope = try await catalog(for: account).openScope(accountID: account)
            guard !fm.fileExists(atPath: scope.database.primary.path) else { throw V2AccountLocalStoreError.migrationConflict }
            migration = .init(version: 1, accountID: account.rawValue, incarnation: scope.incarnation)
            try JSONEncoder().encode(migration).write(to: migrationURL, options: .atomic)
        } else {
            // An orphan FTS has no independently trusted account association.
            for file in legacy.files.dropFirst(3) where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            migrationFinished = true
            return
        }
        let account = try UserID(migration.accountID)
        let scope = try await catalog(for: account).openScope(accountID: account)
        guard scope.incarnation == migration.incarnation else { throw V2AccountLocalStoreError.migrationConflict }
        guard fm.fileExists(atPath: legacy.primary.path) || fm.fileExists(atPath: scope.database.primary.path) else {
            throw V2AccountLocalStoreError.migrationConflict
        }
        // Each rename is atomic on this application-support volume. The
        // committed marker lets restart finish any prefix before opening pools.
        for (source, destination) in zip(legacy.files.prefix(3), scope.database.files.prefix(3)) {
            if fm.fileExists(atPath: source.path) {
                guard !fm.fileExists(atPath: destination.path) else { throw V2AccountLocalStoreError.migrationConflict }
                try fm.moveItem(at: source, to: destination)
            }
        }
        // Rebuild search from the validated primary; never import global FTS.
        try legacy.removeClosedFiles()
        try fm.removeItem(at: migrationURL)
        migrationFinished = true
    }
}
