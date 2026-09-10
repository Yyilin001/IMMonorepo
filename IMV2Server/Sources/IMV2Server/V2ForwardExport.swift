import Crypto
import Foundation
import IMV2Core

/// 来源归属出具的转发授权，而不是目标侧的接受回执。
///
/// 投递必须原样传输这里的字节；对重新编码的 JSON 求哈希不足以校验该导出，
/// 因为目标侧会按摘要逐字节复核。
public struct V2ForwardExport: Equatable, Sendable {
    /// 逐字节参与校验的序列化载荷。
    public let payload: Data
    /// 载荷的 SHA-256 摘要。
    public let digest: Data
    /// 从载荷解码并校验后的转发意图。
    public let intent: V2ForwardExportIntent

    /// 以键序稳定的 JSON 编码意图并计算摘要。
    ///
    /// - Parameter intent: 待导出的转发意图。
    /// - Throws: 编码失败，或生成的载荷不满足导出约束时抛出
    ///   ``V2ForwardExportError/corruptPersistenceState``。
    init(intent: V2ForwardExportIntent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(intent)
        try self.init(payload: payload, digest: Data(SHA256.hash(data: payload)))
    }

    /// 校验载荷与摘要后构造导出。
    ///
    /// 载荷非空且不超过 1 MiB，摘要必须是 32 字节并与载荷的 SHA-256 完全一致；
    /// 意图的版本、修订、代次、分片标识、媒体数量与媒体字段都会逐一校验。
    ///
    /// - Parameters:
    ///   - payload: 待校验的原始载荷。
    ///   - digest: 期望的载荷摘要。
    /// - Throws: 载荷或摘要不满足约束、意图字段越界、媒体标识重复，
    ///   或富文本内容校验失败时抛出 ``V2ForwardExportError/corruptPersistenceState``。
    init(payload: Data, digest: Data) throws {
        guard !payload.isEmpty, payload.count <= 1_048_576,
              digest.count == 32, Data(SHA256.hash(data: payload)) == digest
        else { throw V2ForwardExportError.corruptPersistenceState }
        let intent = try JSONDecoder().decode(V2ForwardExportIntent.self, from: payload)
        guard intent.version == 1, intent.sourceRevision > 0,
              intent.sourceEpoch >= 0, intent.targetEpoch >= 0,
              !intent.sourceShardID.isEmpty, !intent.targetShardID.isEmpty,
              intent.media.count <= V2MessageCommandLimits.maxMediaAttachments,
              Set(intent.media.map(\.mediaID)).count == intent.media.count,
              intent.media.allSatisfy({ $0.byteCount > 0 && !$0.contentType.isEmpty && $0.contentType.utf8.count <= 127 })
        else { throw V2ForwardExportError.corruptPersistenceState }
        try V2RichMessageContent.validate(text: intent.text, entities: intent.entities)
        self.payload = payload
        self.digest = digest
        self.intent = intent
    }
}

/// 导出清单中的单个媒体条目。
///
/// 持久化导出不包含下载地址或提供方凭据；摘要只绑定清单元数据，
/// 不绑定尚未导入的媒体字节。
public struct V2ForwardExportMedia: Codable, Equatable, Sendable {
    /// 媒体标识。
    public let mediaID: UUID
    /// 源端上传会话标识。
    public let uploadSessionID: UUID
    /// 媒体内容类型。
    public let contentType: String
    /// 媒体字节数。
    public let byteCount: Int64
}

/// 可跨归属传输的转发意图。
///
/// 同时携带源房间与目标房间的版本、归属代次与创建身份，
/// 目标侧据此校验归属并复用幂等接受语义。
public struct V2ForwardExportIntent: Codable, Equatable, Sendable {
    public let version: Int
    public let exportID: UUID
    public let actorUserID: UUID
    public let operationID: UUID
    public let sourceRoomID: UUID
    public let sourceMessageID: UUID
    public let sourceRevision: Int64
    public let sourceSenderUserID: UUID
    public let sourceShardID: String
    public let sourceEpoch: Int64
    public let targetRoomID: UUID
    public let targetClientMessageID: UUID
    public let targetShardID: String
    public let targetEpoch: Int64
    public let text: String
    public let entities: [V2MessageEntity]
    public let media: [V2ForwardExportMedia]
}

/// 转发导出错误。
public enum V2ForwardExportError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 源消息当前不可用（不存在或不可见）。
    case sourceUnavailable
    /// 源消息在准备期间发生变化。
    case sourceChanged
    /// 源消息引用的媒体不可用。
    case mediaUnavailable
    /// 源或目标房间归属已变更。
    case ownerChanged
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 来源房间准入容量不足。
    case capacityExceeded
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
