import Foundation

/// 取消单次注册的客户端证明，须在签发请求之前保存。
///
/// 使用独立用途前缀，与会话撤销凭证分离；不能用于认证、刷新或取消其他注册。具体绑定关系由包含它的取消材料及服务端校验决定。
/// 默认描述与反射隐藏原文，公开 rawValue 和编码结果仍是敏感材料。
public struct V2DeviceRegistrationCancellationProof: Equatable, Sendable, Codable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// 包含注册取消用途前缀的敏感证明原文。
    public let rawValue: String
    /// 固定用途与版本前缀 imv2-cancel-registration-v1.。
    private static let prefix = "imv2-cancel-registration-v1."

    /// 校验注册取消前缀及规范 256 位 Base64URL 后缀。
    ///
    /// - Parameter rawValue: 带注册取消专用前缀的完整证明。
    /// - Throws: 前缀不符或后缀无法通过规范撤销凭证编码校验时抛出 invalidProof。
    ///
    /// 复用后缀校验不改变该值的用途，也不建立服务端绑定。
    public init(rawValue: String) throws {
        guard rawValue.hasPrefix(Self.prefix) else { throw ValidationError.invalidProof }
        let suffix = String(rawValue.dropFirst(Self.prefix.count))
        // Reuse the canonical 256-bit encoding validator, with a distinct
        // purpose prefix so these values cannot be used as session capability.
        guard (try? V2DeviceRevocationCredential(rawValue: "imv2-revoke-v1." + suffix)) != nil else {
            throw ValidationError.invalidProof
        }
        self.rawValue = rawValue
    }

    /// 复用 32 字节随机凭证生成逻辑，替换为注册取消专用前缀，返回尚待绑定具体操作的证明。
    public static func generate() -> Self {
        let suffix = V2DeviceRevocationCredential.generate().rawValue.dropFirst("imv2-revoke-v1.".count)
        return Self(validatedValue: prefix + suffix)
    }

    /// 内部保存已生成且格式合法的值，不重复校验。
    private init(validatedValue: String) { rawValue = validatedValue }
    /// 解码单个字符串并执行与公开构造器相同的格式校验。
    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }
    /// 编码完整敏感证明原文为单个字符串，供受控传输与持久化使用。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    /// 返回固定脱敏描述，不展示证明内容。
    public var description: String { "V2DeviceRegistrationCancellationProof(<redacted>)" }
    /// 复用脱敏描述作为调试文本。
    public var debugDescription: String { description }
    /// 返回不包含子字段的反射视图，避免常规反射输出证明。
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    /// 证明格式错误；invalidProof 表示用途前缀或规范后缀不合法。
    public enum ValidationError: Error, Equatable, Sendable { case invalidProof }
}

/// 不可变的注册取消身份，绑定设备、操作 UUID、证明与签发截止时间。
///
/// 每次重试必须保留四个字段；模型仅校验表示范围，服务端还需限制允许的未来签发期限。
public struct V2DeviceRegistrationCancellation: Equatable, Sendable, Codable {
    /// 规范化为 UUID 字符串的设备身份。
    public let deviceID: DeviceID
    /// 本次注册及取消流程复用的操作 UUID。
    public let operationID: UUID
    /// 用于证明该注册取消权限的敏感材料。
    public let proof: V2DeviceRegistrationCancellationProof
    /// 签发截止时间，以 Unix 毫秒表示，必须位于 1 到 253402300799000。
    public let issueBeforeMilliseconds: Int64

    /// 校验取消材料的设备与时间范围，并规范化设备 UUID 表示。
    ///
    /// - Parameters:
    ///   - deviceID: 原始值必须可解析为 UUID 的设备标识。
    ///   - operationID: 稳定注册操作身份。
    ///   - proof: 已通过格式校验的注册取消证明。
    ///   - issueBeforeMilliseconds: 介于 1 与 253402300799000 之间的 Unix 毫秒截止时间。
    /// - Throws: 设备不是 UUID 或期限超出范围时抛出 invalidRequest。
    ///
    /// 不读取当前时钟，范围内的过去时间也可构造；是否仍可签发由业务层判断。
    public init(deviceID: DeviceID, operationID: UUID, proof: V2DeviceRegistrationCancellationProof,
                issueBeforeMilliseconds: Int64) throws {
        guard let device = UUID(uuidString: deviceID.rawValue),
              (1...253_402_300_799_000).contains(issueBeforeMilliseconds) else { throw ValidationError.invalidRequest }
        self.deviceID = try DeviceID(device.uuidString)
        self.operationID = operationID
        self.proof = proof
        self.issueBeforeMilliseconds = issueBeforeMilliseconds
    }

    /// 将 Unix 毫秒转换为 Foundation Date，不进行当前时间比较。
    public var issueBefore: Date { Date(timeIntervalSince1970: Double(issueBeforeMilliseconds) / 1_000) }
    /// 解码全部必需字段并调用校验构造器，保持设备规范化与时间范围约束。
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(deviceID: values.decode(DeviceID.self, forKey: .deviceID),
            operationID: values.decode(UUID.self, forKey: .operationID),
            proof: values.decode(V2DeviceRegistrationCancellationProof.self, forKey: .proof),
            issueBeforeMilliseconds: values.decode(Int64.self, forKey: .issueBeforeMilliseconds))
    }
    /// 取消材料的稳定 JSON 字段键，四个字段均参与编码与解码。
    private enum CodingKeys: CodingKey { case deviceID, operationID, proof, issueBeforeMilliseconds }
    /// 取消请求材料校验错误；invalidRequest 表示设备 UUID 或时间范围无效。
    public enum ValidationError: Error, Equatable, Sendable { case invalidRequest }
}
