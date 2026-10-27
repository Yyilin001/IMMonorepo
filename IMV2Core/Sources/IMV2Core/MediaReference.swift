import Foundation

/// 消息载荷中的不透明媒体引用，只包含媒体身份。
///
/// 对象地址与带授权的 URL 不属于持久消息协议，不能嵌入事件或同步投影。
public struct V2MediaReference: Hashable, Codable, Sendable {
    /// 媒体对象身份，不等于下载权限。
    public let mediaID: MediaID
    /// 包装媒体身份，不读取对象或验证可见性。
    public init(mediaID: MediaID) { self.mediaID = mediaID }
}

/// 服务端根据媒体对象派生的持久展示资料，不携带对象地址或下载凭证。
///
/// 构造和解码均校验描述一致性；消息同步边界还必须验证描述归属。
public struct V2MediaPresentation: Hashable, Codable, Sendable {
    /// 媒体展示类别，原始值参与编码。
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// 静态图片类别。
        case image
        /// 动图类别，原始值为 animated_image。
        case animatedImage = "animated_image"
        /// 视频类别。
        case video
        /// 音频类别。
        case audio
        /// 通用文件类别。
        case file
    }

    /// 展示资料对应的媒体身份。
    public let mediaID: MediaID
    /// 显示类别，构造器不检查其与 contentType 一致。
    public let kind: Kind
    /// 已规范化的内容类型字符串，最长 127 个 UTF-8 字节。
    public let contentType: String
    /// 媒体字节数，允许零。
    public let byteCount: Int64
    /// Verified resource facts for durable synchronization. Local draft display
    /// values may omit this; accepted wire projections must include it.
    public let resourceDescriptor: V2ResourceDescriptor?

    /// 要求内容类型已经去除首尾空白并小写、包含斜线、无 ASCII 控制字符且不超过 127 字节，字节数非负，否则抛出 invalidPresentation；不验证完整 MIME 语法。
    public init(mediaID: MediaID, kind: Kind, contentType: String, byteCount: Int64,
                resourceDescriptor: V2ResourceDescriptor? = nil) throws {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedContentType == contentType,
              normalizedContentType.contains("/"),
              !normalizedContentType.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              normalizedContentType.utf8.count <= 127,
              byteCount >= 0
        else { throw V2MediaValidationError.invalidPresentation }
        self.mediaID = mediaID
        self.kind = kind
        self.contentType = normalizedContentType
        if let descriptor = resourceDescriptor {
            guard descriptor.key.mediaID == mediaID, descriptor.kind == kind,
                  descriptor.contentType == contentType, descriptor.byteCount == byteCount,
                  descriptor.state == .ready else { throw V2MediaValidationError.invalidPresentation }
        }
        self.byteCount = byteCount
        self.resourceDescriptor = resourceDescriptor
    }

    private enum CodingKeys: String, CodingKey { case mediaID, kind, contentType, byteCount, resourceDescriptor }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(mediaID: values.decode(MediaID.self, forKey: .mediaID), kind: values.decode(Kind.self, forKey: .kind),
            contentType: values.decode(String.self, forKey: .contentType), byteCount: values.decode(Int64.self, forKey: .byteCount),
            resourceDescriptor: values.decodeIfPresent(V2ResourceDescriptor.self, forKey: .resourceDescriptor))
    }

    /// 按区分大小写的前缀分类：image/gif 优先动图，其次 image/、video/、audio/，其余为 file；不验证内容字节，也不先规范化输入。
    public static func kind(forContentType contentType: String) -> Kind {
        if contentType.hasPrefix("image/gif") { return .animatedImage }
        if contentType.hasPrefix("image/") { return .image }
        if contentType.hasPrefix("video/") { return .video }
        if contentType.hasPrefix("audio/") { return .audio }
        return .file
    }
}

/// 经授权取得的不透明短期下载会话，媒体服务将其换取具体对象目标。
///
/// 对象地址及 Bearer 凭证不属于持久聊天状态。
public struct V2MediaDownloadGrant: Equatable, Sendable {
    /// 授权关联的媒体身份。
    public let mediaID: MediaID
    /// 不透明下载会话身份。
    public let downloadSessionID: MediaDownloadSessionID
    /// 下载会话期限。
    public let expiresAt: Date

    /// 保存下载会话字段，不读取时钟或检查当前可见性。
    public init(mediaID: MediaID, downloadSessionID: MediaDownloadSessionID, expiresAt: Date) {
        self.mediaID = mediaID
        self.downloadSessionID = downloadSessionID
        self.expiresAt = expiresAt
    }
}

/// 已认证边缘返回的临时下载计划；不可写入消息、投影、journal、备份或日志。
/// 下载只接受完整 GET，并要求长度和摘要，解码与普通构造使用同一校验。
public enum V2MediaImagePreviewSize: Int, Codable, Sendable { case thumbnail = 320, large = 1280 }

public struct V2MediaDownloadTargetEnvelope: Codable, Equatable, Sendable {
    public let plan: V2ResourceTransferPlan
    public let preview: V2ResourceVariantDescriptor?

    public init(plan: V2ResourceTransferPlan, preview: V2ResourceVariantDescriptor? = nil) throws {
        guard plan.mode == .httpGet, plan.checksum != nil
        else { throw V2MediaValidationError.invalidDownloadTarget }
        if let preview {
            guard case .derived = preview.key.rendition, preview.checksum == plan.checksum,
                  preview.byteCount == plan.expectedByteCount, preview.byteCount <= 2 * 1_024 * 1_024
            else { throw V2MediaValidationError.invalidDownloadTarget }
        }
        self.plan = plan; self.preview = preview
    }

    private enum CodingKeys: String, CodingKey { case plan, preview }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(plan: values.decode(V2ResourceTransferPlan.self, forKey: .plan),
                      preview: values.decodeIfPresent(V2ResourceVariantDescriptor.self, forKey: .preview))
    }
}

/// 短期下载授权寿命配置，最长十五分钟。
public struct V2MediaDownloadLimits: Equatable, Sendable {
    /// 授权寿命，单位秒，默认 120。
    public let grantLifetime: TimeInterval

    /// 要求寿命大于零且不超过 900 秒，否则抛出 invalidLimits；有限范围也排除 NaN 和正无穷。
    public init(grantLifetime: TimeInterval = 120) throws {
        guard grantLifetime > 0, grantLifetime <= 900 else {
            throw V2MediaValidationError.invalidLimits
        }
        self.grantLifetime = grantLifetime
    }

    /// 默认 120 秒下载授权配置，由已知有效常量构造。
    public static let standard = try! V2MediaDownloadLimits()
}

/// 媒体生命周期状态，由显式事件推动，不等同于提供方即时文件状态。
public enum V2MediaObjectState: String, Codable, Equatable, Sendable {
    /// 等待上传完成。
    case pendingUpload
    /// 上传完成，等待扫描结论。
    case scanning
    /// 扫描通过，可供业务授权使用。
    case available
    /// 扫描失败。
    case failed
    /// 对象已过期。
    case expired
}

/// 驱动媒体生命周期的业务事件。
public enum V2MediaLifecycleEvent: Equatable, Sendable {
    /// 提供方上传完成事实。
    case uploadCompleted
    /// 扫描通过事实。
    case scanPassed
    /// 扫描失败事实。
    case scanFailed
    /// 显式过期事件。
    case expire
}

/// 媒体对象的不可变领域快照，状态转换返回新值，不在模型中执行上传或扫描。
public struct V2MediaObject: Equatable, Sendable {
    /// 媒体对象身份。
    public let mediaID: MediaID
    /// 对象所有者。
    public let ownerUserID: UserID
    /// 对象内容类型。
    public let contentType: String
    /// 对象字节数。
    public let byteCount: Int64
    /// 当前生命周期状态。
    public let state: V2MediaObjectState
    /// 对象生命周期截止时间。
    public let expiresAt: Date

    /// 直接保存所有字段，默认 pendingUpload；不校验类型、大小、日期或初始状态，调用方负责构造一致快照。
    public init(mediaID: MediaID, ownerUserID: UserID, contentType: String, byteCount: Int64, state: V2MediaObjectState = .pendingUpload, expiresAt: Date) {
        self.mediaID = mediaID
        self.ownerUserID = ownerUserID
        self.contentType = contentType
        self.byteCount = byteCount
        self.state = state
        self.expiresAt = expiresAt
    }
}

/// 媒体生命周期纯值转换规则，不执行持久化、扫描或提供方删除。
public enum V2MediaLifecycle {
    /// 根据当前状态、事件及截止时间生成新对象快照。
    ///
    /// - Parameters:
    ///   - object: 当前完整对象快照。
    ///   - event: 上传完成、扫描通过、扫描失败或过期事件。
    ///   - now: 调用方提供的判断时间。
    /// - Returns: 保留身份及元数据、只更新状态的新快照。
    /// - Throws: 到期后收到不允许事件时抛出 expired，其他非法状态组合抛出 invalidStateTransition。
    ///
    /// 恰好到期按已过期处理：expire 事件或原状态已 expired 时返回 expired，否则拒绝。
    /// 到期前仅允许 pendingUpload 到 scanning、scanning 到 available/failed，以及 pendingUpload/scanning 显式过期。
    /// 已失败对象到期后仍可通过 expire 变为 expired；不会恢复为可用。
    public static func transition(_ object: V2MediaObject, event: V2MediaLifecycleEvent, now: Date) throws -> V2MediaObject {
        if now >= object.expiresAt {
            guard event == .expire || object.state == .expired else { throw V2MediaValidationError.expired }
            return .init(mediaID: object.mediaID, ownerUserID: object.ownerUserID, contentType: object.contentType, byteCount: object.byteCount, state: .expired, expiresAt: object.expiresAt)
        }
        let state: V2MediaObjectState
        switch (object.state, event) {
        case (.pendingUpload, .uploadCompleted): state = .scanning
        case (.scanning, .scanPassed): state = .available
        case (.scanning, .scanFailed): state = .failed
        case (.pendingUpload, .expire), (.scanning, .expire): state = .expired
        default: throw V2MediaValidationError.invalidStateTransition
        }
        return .init(mediaID: object.mediaID, ownerUserID: object.ownerUserID, contentType: object.contentType, byteCount: object.byteCount, state: state, expiresAt: object.expiresAt)
    }
}

/// 媒体字段、生命周期或附件组合的校验错误。
public enum V2MediaValidationError: Error, Equatable, Sendable {
    /// 寿命或容量配置不符合对应构造器要求。
    case invalidLimits
    /// 上传意图的内容类型或字节数无效。
    case invalidUploadIntent
    /// 当前媒体状态不允许该事件。
    case invalidStateTransition
    /// 对象已经到期，不能继续执行该生命周期事件。
    case expired
    /// 附件集合不符合业务约束。
    case invalidAttachmentSet
    /// 临时下载目标字段无效。
    case invalidDownloadTarget
    /// 持久展示资料字段无效。
    case invalidPresentation
}
