import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit


/// 基于 PostgreSQL 的密码账号存储实现。
public struct V2PostgresPasswordAccountStore: V2PasswordAccountStoring, Sendable {
    private let database: any Database
    private let now: @Sendable () -> Date

    /// 组合数据库与授时来源。
    ///
    /// - Parameters:
    ///   - database: 存放密码凭据、公开资料与审计的数据库。
    ///   - now: 可注入的当前时刻读取函数。
    public init(database: any Database, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.now = now
    }

    /// 在单个事务内注册新账号。
    ///
    /// 事务先按账号标识与公开账号名分别加咨询锁，再校验两者未被占用，随后写入密码凭据、
    /// 初始公开资料与注册成功审计。任一占用检查失败都会整体回滚。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - passwordHash: 已完成的密码哈希串，需符合部署策略。
    ///   - publicHandle: 公开账号名。
    ///   - displayName: 展示名称。
    ///   - deviceID: 发起注册的设备。
    /// - Returns: 新账号的用户标识。
    /// - Throws: 账号标识非法时抛出
    ///   ``V2PasswordAccountStoreError/invalidAccountHandle``；公开身份不合法时抛出
    ///   ``V2PasswordAccountStoreError/invalidPublicIdentity``；账号或公开账号名已存在时抛出对应错误；
    ///   哈希参数、连接或时刻不可用时抛出 ``V2PasswordAccountStoreError/unavailable``。
    public func register(
        accountHandle: String,
        passwordHash: String,
        publicHandle: String,
        displayName: String,
        deviceID: DeviceID
    ) async throws -> UserID {
        let handle = try canonicalAccountHandle(accountHandle)
        let userUUID = UUID()
        let identity: V2PublicIdentity
        do {
            identity = try .init(
                userID: .init(userUUID.uuidString),
                handle: .init(publicHandle),
                displayName: displayName,
                accountKind: .regular
            )
        } catch {
            throw V2PasswordAccountStoreError.invalidPublicIdentity
        }
        guard V2PasswordHashPolicy.supports(passwordHash) else { throw V2PasswordAccountStoreError.unavailable }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw V2PasswordAccountStoreError.unavailable
            }
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-account:" + handle), 0))").run()
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "v2-public-handle:" + identity.handle.rawValue), 0))").run()
            guard try await sql.raw("SELECT 1 FROM im_v2.account_password_credentials WHERE account_handle = \(bind: handle)").first() == nil else {
                throw V2PasswordAccountStoreError.accountAlreadyExists
            }
            guard try await sql.raw("SELECT 1 FROM im_v2.public_user_profiles WHERE public_handle = \(bind: identity.handle.rawValue)").first() == nil else {
                throw V2PasswordAccountStoreError.publicHandleAlreadyExists
            }
            let current = now()
            guard v2PostgresTimestampCanEncode(current) else { throw V2PasswordAccountStoreError.unavailable }
            try await sql.raw("INSERT INTO im_v2.account_password_credentials (account_handle, user_id, password_hash, created_at) VALUES (\(bind: handle), \(bind: userUUID), \(bind: passwordHash), \(bind: current))").run()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles (user_id, public_handle, display_name, account_kind, revision, created_at, updated_at) VALUES (\(bind: userUUID), \(bind: identity.handle.rawValue), \(bind: identity.displayName), \(bind: identity.accountKind.rawValue), 1, \(bind: current), \(bind: current))").run()
            try await recordPasswordAuthenticationAudit(
                outcome: .registrationSucceeded,
                userID: identity.userID,
                deviceID: deviceID,
                occurredAt: current,
                on: sql
            )
            return identity.userID
        }
    }

    /// 复核凭据并提交成功审计与失败窗口重置。
    ///
    /// - Parameters:
    ///   - accountHandle: 账号标识。
    ///   - expected: KDF 计算前读取到的凭据。
    ///   - deviceID: 发起登录的设备。
    /// - Returns: 凭据完全一致且账号未被停用时为 `true`。
    /// - Throws: 账号标识非法时抛出
    ///   ``V2PasswordAccountStoreError/invalidAccountHandle``；连接或时刻不可用时抛出
    ///   ``V2PasswordAccountStoreError/unavailable``。
    public func completeAuthentication(accountHandle: String, expected: V2PasswordCredential, deviceID: DeviceID) async throws -> Bool {
        let handle = try canonicalAccountHandle(accountHandle)
        guard V2PasswordHashPolicy.supports(expected.passwordHash) else { return false }
        return try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2PasswordAccountStoreError.unavailable }
            try await v2LockPasswordAttempts(sql, handle: handle)
            guard let row = try await sql.raw("SELECT user_id, password_hash, credential_revision FROM im_v2.account_password_credentials WHERE account_handle=\(bind: handle) FOR SHARE").first(decoding: PasswordCredentialRow.self),
                  row.userID == expected.userID.uuidValue, row.passwordHash == expected.passwordHash, row.revision == expected.revision,
                  try await sql.raw("SELECT 1 FROM im_v2.account_disables WHERE user_id=\(bind: row.userID)").first() == nil else { return false }
            let current = now()
            guard v2PostgresTimestampCanEncode(current) else { throw V2PasswordAccountStoreError.unavailable }
            try await sql.raw("DELETE FROM im_v2.account_password_login_rate_limits WHERE account_handle=\(bind: handle)").run()
            try await recordPasswordAuthenticationAudit(outcome: .assertionSucceeded, userID: expected.userID,
                deviceID: deviceID, occurredAt: current, on: sql)
            return true
        }
    }

    /// 读取账号的密码凭据。
    ///
    /// - Parameter accountHandle: 账号标识。
    /// - Returns: 凭据；账号不存在或已被停用时返回 `nil`。
    /// - Throws: 账号标识非法时抛出
    ///   ``V2PasswordAccountStoreError/invalidAccountHandle``；连接不支持 SQL 时抛出
    ///   ``V2PasswordAccountStoreError/unavailable``。
    public func passwordCredential(for accountHandle: String) async throws -> V2PasswordCredential? {
        let handle = try canonicalAccountHandle(accountHandle)
        guard let sql = database as? any SQLDatabase else {
            throw V2PasswordAccountStoreError.unavailable
        }
        guard let row = try await sql.raw("SELECT credential.user_id, credential.password_hash, credential.credential_revision FROM im_v2.account_password_credentials AS credential LEFT JOIN im_v2.account_disables AS disabled ON disabled.user_id = credential.user_id WHERE credential.account_handle = \(bind: handle) AND disabled.user_id IS NULL").first(decoding: PasswordCredentialRow.self),
              let userID = try? UserID(row.userID.uuidString)
        else { return nil }
        return .init(userID: userID, passwordHash: row.passwordHash, revision: row.revision)
    }
}


private struct PasswordCredentialRow: Decodable {
    let userID: UUID
    let passwordHash: String
    let revision: Int64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case passwordHash = "password_hash"
        case revision = "credential_revision"
    }
}
