import Foundation
import GRDB
import IMV2Core

/// 设备限定凭据中已有的账号绑定，不含令牌，也不是远端授权。
public struct V2LocalAccountIdentity: Equatable, Sendable {
    public let userID: UserID
    public let deviceID: DeviceID
    public let epoch: V2AuthSessionEpoch
    init(userID: UserID, deviceID: DeviceID, epoch: V2AuthSessionEpoch) {
        self.userID = userID; self.deviceID = deviceID; self.epoch = epoch
    }
}

public enum V2OfflineReadBootstrapError: Error, Equatable, Sendable {
    case localExitPending
    case localStoreUnavailable
    case installationBindingUnavailable
    case installationBindingMismatch
}

/// 只允许建立本地读取上下文；不能交给网络客户端或替代 display lease。
/// 由 bootstrapper 发放，使用前须重新检查退出标记、会话代次和安装绑定。
public struct V2OfflineReadBootstrap: Sendable {
    public let identity: V2LocalAccountIdentity
    public let databaseURL: URL
    public let storageScope: V2AccountStorageScope?
    let installationBinding: V2LocalInstallationBinding
    let ownerID: UUID
    init(identity: V2LocalAccountIdentity, databaseURL: URL, storageScope: V2AccountStorageScope?,
         installationBinding: V2LocalInstallationBinding, ownerID: UUID) {
        self.identity = identity; self.databaseURL = databaseURL; self.storageScope = storageScope
        self.installationBinding = installationBinding; self.ownerID = ownerID
    }
}

extension V2LocalStoreBootstrapper {
    /// 验证既有数据库的归属，使用只读 SQLite 连接；绝不创建、修复或擦除数据库。
    func existingBindingForLocalRead(databaseURL: URL, userID: UserID) async throws -> V2LocalInstallationBinding {
        let binding: V2LocalInstallationBinding
        do {
            guard let stored = try await bindingStoreForLocalRead() else {
                throw V2OfflineReadBootstrapError.installationBindingMismatch
            }
            binding = stored
        } catch let error as V2InstallationBindingStoreError {
            switch error {
            case .unavailable, .unexpectedStatus: throw V2OfflineReadBootstrapError.installationBindingUnavailable
            case .malformedRecord, .permanentlyInvalidated: throw V2OfflineReadBootstrapError.installationBindingMismatch
            }
        }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw V2OfflineReadBootstrapError.localStoreUnavailable
        }
        var configuration = Configuration()
        configuration.readonly = true
        let database: DatabaseQueue
        do { database = try DatabaseQueue(path: databaseURL.path, configuration: configuration) }
        catch { throw V2OfflineReadBootstrapError.localStoreUnavailable }
        defer { try? database.close() }
        do {
            let matches = try await database.read { db -> Bool in
                guard let row = try Row.fetchOne(db, sql: "SELECT binding, user_id FROM v2_local_installation WHERE singleton = 1") else { return false }
                let storedBinding: String = row["binding"]
                let storedUser: String? = row["user_id"]
                return storedBinding == binding.value.uuidString && storedUser == userID.rawValue
            }
            guard matches else { throw V2OfflineReadBootstrapError.installationBindingMismatch }
        } catch let error as V2OfflineReadBootstrapError { throw error }
        catch { throw V2OfflineReadBootstrapError.localStoreUnavailable }
        return binding
    }
}
