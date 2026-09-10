import Foundation
import CryptoKit

/// 待删除凭据标记的存储能力。
///
/// 这里只持久化非敏感意图，绝不保存令牌或账号身份；
/// 读取或提交标记失败都不能被当作「已登出」处理。
protocol V2PendingCredentialDeletionStoring: Sendable {
    /// 查询是否存在待完成的凭据删除。
    ///
    /// - Returns: 存在待删除标记时为 `true`。
    /// - Throws: 标记文件损坏或不可读写时抛出。
    func isPending() async throws -> Bool

    /// 标记存在待完成的凭据删除。
    ///
    /// - Throws: 写入失败时抛出。
    func markPending() async throws

    /// 清除待删除标记。
    ///
    /// - Throws: 写入失败时抛出。
    func clearPending() async throws
}

/// 凭据删除标记错误。
enum V2PendingCredentialDeletionError: Error { case invalidRecord }

/// 基于文件的待删除凭据标记存储。
///
/// 在调用方可以删除凭据之前，必须先完成原子文件替换与显式刷盘；
/// 已清除的记录对旧的 `UserDefaults` 标记具有权威性，即使偏好删除尚未刷盘。
actor V2FilePendingCredentialDeletionStore: V2PendingCredentialDeletionStoring {
    /// 由数据库地址与服务标识派生标记文件地址。
    ///
    /// - Parameters:
    ///   - databaseURL: 设备本地数据库地址。
    ///   - legacyKey: 旧版偏好键，用于派生稳定的服务标识哈希。
    /// - Returns: 标记文件地址。
    static func fileURL(databaseURL: URL, legacyKey: String) -> URL {
        let serviceHash = SHA256.hash(data: Data(legacyKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return databaseURL.appendingPathExtension("credential-deletion-" + serviceHash + ".json")
    }
    private struct Record: Codable {
        let version: Int
        let pending: Bool
    }
    private let url: URL
    private let defaults: UserDefaults
    private let legacyKey: String

    /// 构造标记存储。
    ///
    /// - Parameters:
    ///   - url: 标记文件地址。
    ///   - defaults: 读取旧版标记的偏好存储。
    ///   - legacyKey: 旧版偏好键。
    init(url: URL, defaults: UserDefaults = .standard, legacyKey: String) {
        self.url = url
        self.defaults = defaults
        self.legacyKey = legacyKey
    }

    /// 查询是否存在待完成的凭据删除。
    ///
    /// 标记文件缺失时会回退检查旧版偏好键：若旧标记为真则立即迁移为文件标记并返回真。
    ///
    /// - Returns: 存在待删除标记时为 `true`。
    /// - Throws: 文件读取失败（非「不存在」）或记录版本不受支持时抛出
    ///   ``V2PendingCredentialDeletionError/invalidRecord``。
    func isPending() throws -> Bool {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile {
            guard defaults.bool(forKey: legacyKey) else { return false }
            try markPending()
            return true
        }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw V2PendingCredentialDeletionError.invalidRecord }
        guard record.version == 1 else { throw V2PendingCredentialDeletionError.invalidRecord }
        return record.pending
    }

    /// 标记存在待完成的凭据删除。
    ///
    /// - Throws: 写入失败时抛出。
    func markPending() throws { try write(pending: true) }

    /// 清除待删除标记。
    ///
    /// - Throws: 写入失败时抛出。
    func clearPending() throws { try write(pending: false) }

    /// 原子写入标记并同步落盘。
    ///
    /// 写入会先确保受管目录存在、采用原子替换、应用设备本地存储保护策略并显式刷盘，
    /// 最后才清除旧版偏好键，避免出现「文件已清除但旧标记仍在」的中间态。
    ///
    /// - Parameter pending: 目标标记取值。
    /// - Throws: 目录准备、文件写入或刷盘失败时抛出。
    private func write(pending: Bool) throws {
        _ = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(url.deletingLastPathComponent())
        try JSONEncoder().encode(Record(version: 1, pending: pending)).write(to: url, options: .atomic)
        try V2DeviceLocalStoragePolicy.applyToManagedFile(url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
        defaults.removeObject(forKey: legacyKey)
    }
}
