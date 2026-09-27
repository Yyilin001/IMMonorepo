import Crypto
import Foundation

/// 服务端原始发送意图的稳定摘要，与消息可编辑投影分离。
///
/// 在已验证命令构造时计算 SHA-256，使存储适配器在持锁期间只需绑定固定长度摘要。
/// 摘要表达输入一致性，不证明发送者权限，也不替代房间／actor／命令 ID 的去重范围。
public struct V2SendMessageFingerprint: Equatable, Codable, Sendable {
    /// 房间日志发送的统一编码版本，普通发送与转发使用同一合同。
    public static let currentVersion: UInt16 = 3
    /// 决定摘要编码合同的版本，必须与 digest 一起持久化和比较。
    public let version: UInt16
    /// 32 字节 SHA-256 摘要；不可由后续编辑或撤回后的正文重新构造。
    public let digest: Data

    /// 验证从持久化读取的指纹外形。
    ///
    /// - Parameters:
    ///   - version: 当前支持的房间日志发送版本 3。
    ///   - digest: 恰好 32 字节的摘要。
    /// - Throws: 不支持的版本或错误摘要长度抛出 invalidStoredFingerprint。
    ///
    /// 此入口不重新计算内容，存储层仍须保证摘要来自原接受操作。
    public init(version: UInt16, digest: Data) throws {
        guard version == Self.currentVersion, digest.count == 32 else {
            throw V2SendMessageFingerprintError.invalidStoredFingerprint
        }
        self.version = version
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey { case version, digest }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(UInt16.self, forKey: .version), digest: values.decode(Data.self, forKey: .digest))
    }

    /// 从已经验证的命令字段计算原始输入指纹。
    ///
    /// 普通发送与转发统一编码；转发包含所选源版本。
    /// 实体偏移、长度等值必须由命令构造边界验证后传入，
    /// 此内部入口中的无符号转换不再次承担外部输入验证。
    init(
        roomID: RoomID,
        senderUserID: UserID,
        clientMessageID: ClientMessageID,
        text: String,
        media: [V2MediaReference],
        mentions: [V2MentionTarget],
        entities: [V2MessageEntity],
        replyTo: V2MessageReplyReference?,
        forwardedFrom: V2ForwardMessageSource?
    ) {
        let version = Self.currentVersion
        var encoder = SendMessageFingerprintEncoder()
        encoder.string("im.v2.send-message")
        encoder.integer(UInt64(version))
        encoder.string(roomID.rawValue)
        encoder.string(senderUserID.rawValue)
        encoder.string(clientMessageID.rawValue)
        // Preserve exact accepted UTF-8, including whitespace and Unicode
        // composition. Do not silently normalize content only for deduplication.
        encoder.string(text)
        encoder.integer(UInt64(media.count))
        for item in media { encoder.string(item.mediaID.rawValue) }
        encoder.integer(UInt64(mentions.count))
        for mention in mentions {
            switch mention {
            case .user(let userID):
                encoder.tag(1)
                encoder.string(userID.rawValue)
            case .everyone:
                encoder.tag(2)
            }
        }
        encoder.integer(UInt64(entities.count))
        for entity in entities {
            encoder.integer(UInt64(entity.offsetUTF16))
            encoder.integer(UInt64(entity.lengthUTF16))
            encoder.string(entity.kind.rawValue)
            encoder.optionalString(entity.linkURL?.absoluteString)
        }
        encoder.optionalString(replyTo?.messageID.rawValue)
        if let forwardedFrom {
            encoder.tag(1)
            encoder.string(forwardedFrom.messageID.rawValue)
            encoder.string(forwardedFrom.senderUserID.rawValue)
            encoder.integer(forwardedFrom.sourceRevision.rawValue)
        } else {
            encoder.tag(0)
        }
        self.version = version
        self.digest = Data(encoder.hasher.finalize())
    }
}

/// 原指纹持久化记录无法按当前支持的格式解释。
public enum V2SendMessageFingerprintError: Error, Equatable, Sendable {
    /// 摘要长度不是 32 字节，或指纹版本不受支持。
    case invalidStoredFingerprint
}

/// 指纹专用的确定性 SHA-256 输入编码器。
///
/// 整数为大端 UInt64；字符串为长度前缀 UTF-8；变体／可选值使用单字节标记。
/// 保留数组顺序、正文空白和 Unicode 组合，不使用 JSON 键顺序、随机 Hasher 或分隔符拼接。
private struct SendMessageFingerprintEncoder {
    var hasher = SHA256()

    /// 将一个变体或存在性标记加入摘要。
    mutating func tag(_ value: UInt8) {
        hasher.update(data: [value])
    }

    /// 按固定八字节大端格式写入数量或版本，避免平台字长影响摘要。
    mutating func integer(_ value: UInt64) {
        var bytes = value.bigEndian
        withUnsafeBytes(of: &bytes) { hasher.update(bufferPointer: $0) }
    }

    /// 先写 UTF-8 字节长度，再写完整内容，避免拼接歧义。
    mutating func string(_ value: String) {
        let bytes = Data(value.utf8)
        integer(UInt64(bytes.count))
        hasher.update(data: bytes)
    }

    /// 先区分 nil 与存在，再编码字符串，使 nil 与空字符串具有不同摘要。
    mutating func optionalString(_ value: String?) {
        if let value {
            tag(1)
            string(value)
        } else {
            tag(0)
        }
    }
}
