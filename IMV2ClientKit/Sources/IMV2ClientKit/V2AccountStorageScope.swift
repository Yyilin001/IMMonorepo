import Foundation
import IMV2Core

public struct V2AccountStorageRoots: Equatable, Sendable {
    public let persistent: URL
    public let cache: URL
    public init(persistent: URL, cache: URL) {
        self.persistent = persistent.standardizedFileURL
        self.cache = cache.standardizedFileURL
    }
}

/// 同一主数据库生命周期内的 SQLite 工件集合。
///
/// 包含主库、独立搜索库及两者的 WAL／SHM。删除前调用方必须停止所有访问者并关闭
/// 两个连接池；此值只计算文件路径，不拥有任务或连接，也不会自行证明资源已经关闭。
public struct V2LocalDatabaseArtifacts: Sendable, Equatable {
    /// 主数据库文件位置，作为派生搜索库与日志路径的基准。
    public let primary: URL
    /// 独立搜索数据库位置；标准 V2.sqlite 对应 V2Search.sqlite，其他名称使用 .search.sqlite 后缀。
    public var search: URL {
        let name = primary.lastPathComponent == "V2.sqlite"
            ? "V2Search.sqlite" : primary.deletingPathExtension().lastPathComponent + ".search.sqlite"
        return primary.deletingLastPathComponent().appending(path: name)
    }
    /// 主库及其 WAL／SHM，随后为搜索库及其 WAL／SHM；清理调用依赖此固定分组顺序。
    public var files: [URL] {
        [primary, search].flatMap { url in
            [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        }
    }
    /// 从主数据库位置计算其关联工件，不读取或创建文件。
    ///
    /// - Parameter primary: 主数据库 URL；调用方负责提供受管目录中的路径。
    public init(primary: URL) { self.primary = primary }

    /// 删除已关闭数据库的全部现存工件。
    ///
    /// - Parameter fileManager: 执行文件存在性检查与删除的文件管理器。
    /// - Throws: 任一删除失败时保留文件系统错误；此前成功删除的文件不会恢复。
    /// - Important: 方法不会关闭数据库。调用前必须完成访问任务收尾和连接池关闭。
    func removeClosedFiles(fileManager: FileManager = .default) throws {
        for url in files where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

/// 账号数据的一次目录实例，使用不透明 incarnation 标识删除范围。
///
/// 目录退役后，同一账号的新实例使用另一个目录。普通关闭并不等于退役，
/// 同一有效 scope 可供该账号后续重新打开；不能把账号名直接用作迟到清理的目标。
public struct V2AccountStorageScope: Equatable, Sendable {
    /// 目录实例身份，区别同一账号退役前后的存储范围。
    public let incarnation: UUID
    /// 此目录绑定的领域账号；其存在不代替当前会话认证。
    public let accountID: UserID
    /// 数据库、唯一原件及保留字节的持久根。
    public let directory: URL
    /// 可重建字节的独立系统 Caches 根；与持久根使用同一 incarnation。
    public let cacheDirectory: URL
    public init(incarnation: UUID, accountID: UserID, directory: URL, cacheDirectory: URL) {
        self.incarnation = incarnation; self.accountID = accountID
        self.directory = directory.standardizedFileURL; self.cacheDirectory = cacheDirectory.standardizedFileURL
    }
    /// 当前实例的主库、搜索库及日志工件位置。
    public var database: V2LocalDatabaseArtifacts { .init(primary: directory.appending(path: "V2.sqlite")) }
    /// Unified, journal-owned resources for this exact account incarnation.
    public var resourceFilesDirectory: URL { directory.appending(path: "resources", directoryHint: .isDirectory) }
    public var resourceCacheDirectory: URL { cacheDirectory.appending(path: "resources", directoryHint: .isDirectory) }
    /// Minimal AFU handoff is a sibling of the Complete-protected account
    /// directory. Its opaque incarnation still belongs to the same retirement.
    public var backgroundDirectory: URL { directory.appendingPathExtension("background") }
}

/// 账号目录记录无效、范围不匹配或清理顺序不满足约束时的错误。
public enum V2AccountStorageError: Error, Equatable, Sendable {
    case invalidManifest, scopeMismatch, cleanupRequired, storesAlreadyOpened
}

/// 管理账号目录的有效记录、退役标记与可恢复文件删除。
///
/// 调用者先停止新工作，再退役目录、等待任务和关闭数据库，最后完成清理。
/// 新进程可在发放任何 scope 前恢复退役目录清理。本 actor 不保存网络凭据或 Keychain
/// 内容，也不负责撤销账号认证；文件生命周期与认证生命周期需由上层协调。
public actor V2AccountStorageDirectory {
    private struct Entry: Codable, Equatable {
        let version: Int
        let incarnation: UUID
        let accountID: String
    }
    private let root: URL
    private let cacheRoot: URL
    private let fileManager = FileManager.default
    private var prepared = false
    private var hasIssuedScope = false
    private var recovered = false

    /// 创建目录记录管理器，暂不访问磁盘。
    ///
    /// - Parameter root: 当前目录管理器独占的受管根；内部使用标准化 URL。
    public init(root: URL, cacheRoot: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.cacheRoot = cacheRoot.standardizedFileURL.resolvingSymlinksInPath()
    }
    private var activeURL: URL { root.appending(path: "active.json") }
    private var retiredDirectory: URL { root.appending(path: "retired", directoryHint: .isDirectory) }
    private func markerURL(_ id: UUID) -> URL { retiredDirectory.appending(path: id.uuidString + ".json") }
    private func scope(_ entry: Entry) throws -> V2AccountStorageScope {
        guard entry.version == 1 else { throw V2AccountStorageError.invalidManifest }
        return .init(incarnation: entry.incarnation, accountID: try UserID(entry.accountID),
                     directory: root.appending(path: entry.incarnation.uuidString, directoryHint: .isDirectory),
                     cacheDirectory: cacheRoot.appending(path: entry.incarnation.uuidString, directoryHint: .isDirectory))
    }
    private func read(_ url: URL) throws -> Entry? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
            _ = try scope(entry)
            return entry
        } catch { throw V2AccountStorageError.invalidManifest }
    }
    private func prepare() throws {
        guard !prepared else { return }
        guard root.isFileURL, cacheRoot.isFileURL, root != cacheRoot,
              root.resolvingSymlinksInPath().path == root.path, cacheRoot.resolvingSymlinksInPath().path == cacheRoot.path else { throw V2AccountStorageError.scopeMismatch }
        try fileManager.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: root)
        prepared = true
    }
    /// 读取未被退役标记覆盖的 active 记录；用于拒绝退役写入后、active 删除前的崩溃残留。
    private func active() throws -> Entry? {
        guard let entry = try read(activeURL) else { return nil }
        // The marker is committed first. A crash before removing active.json
        // must not reopen the directory whose deletion has already begun.
        if fileManager.fileExists(atPath: markerURL(entry.incarnation).path) { return nil }
        return entry
    }

    /// 仅读取既有有效目录；不创建目录、不恢复清理、不改写 manifest。
    public func existingScopeForLocalRead(accountID: UserID) throws -> V2AccountStorageScope {
        guard let entry = try active(), entry.accountID == accountID.rawValue else {
            throw V2OfflineReadBootstrapError.localStoreUnavailable
        }
        return try scope(entry)
    }

    /// 恢复启动清理后，复用当前账号的有效目录或创建新实例。
    ///
    /// 首次发放 scope 前会处理退役标记。已有不同账号的有效记录时不会偷偷改绑。
    /// 新目录的 active 记录使用原子写入；方法本身不打开数据库连接。
    ///
    /// - Parameter accountID: 已由上层认证确认的数据归属账号。
    /// - Returns: 绑定该账号的有效目录实例。
    /// - Throws: 清理未完成、记录无效、账号不匹配或文件系统错误。
    public func openScope(accountID: UserID) throws -> V2AccountStorageScope {
        try prepare()
        if !recovered { try resumeCleanupBeforeOpeningStores() }
        hasIssuedScope = true
        if let entry = try active() {
            guard entry.accountID == accountID.rawValue else { throw V2AccountStorageError.cleanupRequired }
            return try scope(entry)
        }
        let entry = Entry(version: 1, incarnation: UUID(), accountID: accountID.rawValue)
        let result = try scope(entry)
        try fileManager.createDirectory(at: result.directory, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: result.cacheDirectory, withIntermediateDirectories: true)
        try V2LocalBackupExclusion.apply(to: result.directory)
        try JSONEncoder().encode(entry).write(to: activeURL, options: .atomic)
        return result
    }

    /// 先持久化退役栅栏，再撤下 active 记录；可重复退役同一实例。
    ///
    /// 即使进程在两步之间中断，下次读取也不会重新打开已有退役标记的目录。
    ///
    /// - Parameter candidate: 与本管理器的根、实例和账号记录一致的 scope。
    /// - Throws: 范围／记录不匹配或文件系统错误。
    /// - Important: 应在等待异步任务取消前执行；此方法不删除目录内容。
    public func retire(_ candidate: V2AccountStorageScope) throws {
        try prepare()
        let entry = Entry(version: 1, incarnation: candidate.incarnation, accountID: candidate.accountID.rawValue)
        guard try scope(entry) == candidate else { throw V2AccountStorageError.scopeMismatch }
        if let marker = try read(markerURL(candidate.incarnation)) {
            guard marker == entry else { throw V2AccountStorageError.scopeMismatch }
            return
        }
        guard try active() == entry else { throw V2AccountStorageError.scopeMismatch }
        try JSONEncoder().encode(entry).write(to: markerURL(entry.incarnation), options: .atomic)
        try fileManager.removeItem(at: activeURL)
    }

    /// 等待调用者关闭资源后删除指定的退役目录。
    ///
    /// await 前后都验证退役范围，允许旧实例等待收尾期间创建其他实例。
    /// 已完成删除的范围直接返回，不再次调用关闭闭包；关闭失败保留退役标记供恢复。
    ///
    /// - Parameters:
    ///   - candidate: 已持久退役的原目录实例。
    ///   - close: 停止所有访问者并关闭数据库的异步操作，成功后才允许删除。
    /// - Throws: 范围验证、关闭闭包或文件删除错误。
    public func completeCleanup(
        _ candidate: V2AccountStorageScope,
        afterClosing close: @Sendable () async throws -> Void
    ) async throws {
        guard try validateRetired(candidate) else { return }
        try await close()
        guard try validateRetired(candidate) else { return }
        try removeRetired(candidate)
    }

    /// 在本进程尚未发放 scope 时恢复退役目录的删除。
    ///
    /// 退役标记是跨重启的删除依据，处理完成后才允许打开存储。
    ///
    /// - Throws: 已发放 scope 时抛出 storesAlreadyOpened；否则保留记录解析或删除错误。
    public func resumeCleanupBeforeOpeningStores() throws {
        guard !hasIssuedScope else { throw V2AccountStorageError.storesAlreadyOpened }
        try prepare()
        for url in try fileManager.contentsOfDirectory(at: retiredDirectory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json", let entry = try read(url), url.lastPathComponent == markerURL(entry.incarnation).lastPathComponent else {
                throw V2AccountStorageError.invalidManifest
            }
            try removeRetired(scope(entry))
        }
        recovered = true
    }

    /// 验证原实例的路径和退役身份；返回 false 仅表示该范围已经清理且不再 active。
    private func validateRetired(_ candidate: V2AccountStorageScope) throws -> Bool {
        let expected = Entry(version: 1, incarnation: candidate.incarnation, accountID: candidate.accountID.rawValue)
        guard try scope(expected) == candidate else { throw V2AccountStorageError.scopeMismatch }
        guard let entry = try read(markerURL(candidate.incarnation)) else {
            guard !fileManager.fileExists(atPath: candidate.directory.path),
                  !fileManager.fileExists(atPath: candidate.cacheDirectory.path),
                  !fileManager.fileExists(atPath: candidate.backgroundDirectory.path),
                  try active()?.incarnation != candidate.incarnation else { throw V2AccountStorageError.scopeMismatch }
            return false
        }
        guard entry == expected else { throw V2AccountStorageError.scopeMismatch }
        return true
    }
    /// 按捕获的实例目录删除内容及其记录；只有 active 仍指向该实例时才移除 active 文件。
    private func removeRetired(_ candidate: V2AccountStorageScope) throws {
        // Never consult the current account name for the deletion target.
        guard root.resolvingSymlinksInPath().path == root.path, cacheRoot.resolvingSymlinksInPath().path == cacheRoot.path else { throw V2AccountStorageError.scopeMismatch }
        if fileManager.fileExists(atPath: candidate.directory.path) { try fileManager.removeItem(at: candidate.directory) }
        if fileManager.fileExists(atPath: candidate.cacheDirectory.path) { try fileManager.removeItem(at: candidate.cacheDirectory) }
        if fileManager.fileExists(atPath: candidate.backgroundDirectory.path) { try fileManager.removeItem(at: candidate.backgroundDirectory) }
        if try read(activeURL)?.incarnation == candidate.incarnation { try fileManager.removeItem(at: activeURL) }
        try fileManager.removeItem(at: markerURL(candidate.incarnation))
    }
}
