import Foundation

/// 密码哈希错误。
public enum V2PasswordHashError: Error, Equatable, Sendable {
    /// 输入密码或哈希串不满足约束。
    case invalidInput
    /// 并发额度已满，调用方可稍后重试。
    case busy
    /// 工作器已进入关闭流程。
    case stopped
    /// 底层 KDF 计算失败或输出不符合策略。
    case derivationFailed
}

/// 密码哈希策略常量。
///
/// 计算参数固定为部署选定的单一组合，数据库中的记录无法要求任意内存、迭代次数或并行度。
public enum V2PasswordHashPolicy {
    /// Argon2id 内存开销（KiB）。
    public static let memoryKiB: UInt32 = 65_536
    /// Argon2id 迭代次数。
    public static let iterations: UInt32 = 3
    /// Argon2id 并行度。
    public static let parallelism: UInt32 = 1
    /// Argon2 算法版本号。
    public static let algorithmVersion: UInt32 = 19

    // 用于等成本拒绝的固定公开校验值；它不代表任何账户。
    /// 等代价拒绝使用的固定公开校验串，不对应任何真实账号。
    public static let dummyDigest = "$argon2id$v=19$m=65536,t=3,p=1$aW0tdjItZHVtbXktc2FsdA$9tW2aGVfIp/L14eL1G4XTaY+ksHcPZCQLoqjvLwIkq8"

    /// 判断密码是否满足长度约束且不含 NUL 字节。
    ///
    /// - Parameter password: 待校验密码。
    /// - Returns: 字节长度落在 `12...1024` 且不含零字节时为 `true`。
    public static func accepts(_ password: String) -> Bool {
        (12...1_024).contains(password.utf8.count) && !password.utf8.contains(0)
    }

    /// 判断哈希串是否符合本部署的参数策略。
    ///
    /// 校验在分配 KDF 内存之前完成：只接受部署固定的算法、版本与参数组合，
    /// 数据库中的记录不能要求任意内存、迭代次数或并行度。盐与摘要还必须是无填充的规范 Base64，
    /// 长度分别为 16 与 32 字节。
    ///
    /// - Parameter digest: 待校验的哈希串，长度不超过 128 字节。
    /// - Returns: 完全匹配部署策略时为 `true`。
    public static func supports(_ digest: String) -> Bool {
        guard digest.utf8.count <= 128 else { return false }
        let fields = digest.split(separator: "$", omittingEmptySubsequences: false)
        guard fields.count == 6, fields[0].isEmpty, fields[1] == "argon2id",
              fields[2] == "v=19", fields[3] == "m=65536,t=3,p=1" else { return false }
        return canonicalBase64(fields[4], bytes: 16) && canonicalBase64(fields[5], bytes: 32)
    }

    /// 校验一段无填充 Base64 是否为规范编码且长度正确。
    ///
    /// - Parameters:
    ///   - value: 待校验的 Base64 片段。
    ///   - bytes: 期望解码后的字节数。
    /// - Returns: 解码后长度匹配且重新编码与原文一致时为 `true`。
    private static func canonicalBase64(_ value: Substring, bytes: Int) -> Bool {
        let encoded = String(value)
        let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard !encoded.contains("="), let data = Data(base64Encoded: encoded + padding), data.count == bytes else { return false }
        return data.base64EncodedString().replacingOccurrences(of: "=", with: "") == encoded
    }
}

/// 密码哈希能力。
public protocol V2PasswordHashing: Sendable {
    /// 计算密码哈希。
    ///
    /// - Parameter password: 明文密码。
    /// - Returns: 符合部署策略的哈希串。
    /// - Throws: 输入非法、额度已满或计算失败时抛出。
    func hash(_ password: String) async throws -> String

    /// 校验密码与既有哈希是否匹配。
    ///
    /// - Parameters:
    ///   - password: 明文密码。
    ///   - digest: 已持久化的哈希串。
    /// - Returns: 匹配时为 `true`。
    /// - Throws: 输入非法、额度已满或计算失败时抛出。
    func verify(_ password: String, created digest: String) async throws -> Bool
}
