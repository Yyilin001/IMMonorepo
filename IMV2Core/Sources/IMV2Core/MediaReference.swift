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
/// 合成 Codable 解码不经过普通构造器校验，外部输入应由对应业务边界验证。
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

    /// 要求内容类型已经去除首尾空白并小写、包含斜线、无 ASCII 控制字符且不超过 127 字节，字节数非负，否则抛出 invalidPresentation；不验证完整 MIME 语法。
    public init(mediaID: MediaID, kind: Kind, contentType: String, byteCount: Int64) throws {
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
        self.byteCount = byteCount
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

/// 上传字节上限与临时对象寿命配置。
public struct V2MediaUploadLimits: Equatable, Sendable {
    /// 上传最大字节数，必须为正。
    public let maximumBytes: Int64
    /// 临时对象寿命，单位秒，默认一天。
    public let temporaryLifetime: TimeInterval

    /// 要求字节上限及寿命均大于零，否则抛出 invalidLimits；未额外要求寿命有限，因此正无穷可通过此构造检查。
    public init(maximumBytes: Int64, temporaryLifetime: TimeInterval = 86_400) throws {
        guard maximumBytes > 0, temporaryLifetime > 0 else { throw V2MediaValidationError.invalidLimits }
        self.maximumBytes = maximumBytes
        self.temporaryLifetime = temporaryLifetime
    }
}

/// 持久化上传意图，包含稳定操作身份及媒体元数据，不包含提供方上传地址。
public struct V2RequestMediaUploadCommand: Equatable, Sendable {
    /// 上传意图发起者。
    public let actorUserID: UserID
    /// 本次上传意图的稳定幂等身份。
    public let operationID: MediaUploadOperationID
    /// 预分配媒体身份。
    public let mediaID: MediaID
    /// 已经规范化的内容类型。
    public let contentType: String
    /// 声明的正文件字节数。
    public let byteCount: Int64

    /// 校验内容类型已小写并裁剪、含斜线、无 ASCII 控制字符且不超过 127 字节，同时要求字节数为正且不超过 limits.maximumBytes；失败抛出 invalidUploadIntent，不检查临时寿命。
    public init(actorUserID: UserID, operationID: MediaUploadOperationID, mediaID: MediaID, contentType: String, byteCount: Int64, limits: V2MediaUploadLimits) throws {
        let normalizedContentType = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedContentType == contentType,
              normalizedContentType.contains("/"),
              !normalizedContentType.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              normalizedContentType.utf8.count <= 127,
              byteCount > 0, byteCount <= limits.maximumBytes
        else { throw V2MediaValidationError.invalidUploadIntent }
        self.actorUserID = actorUserID
        self.operationID = operationID
        self.mediaID = mediaID
        self.contentType = normalizedContentType
        self.byteCount = byteCount
    }
}

/// 聊天后端授权的不透明上传会话，由媒体服务换取短期提供方上传目标。
public struct V2MediaUploadGrant: Equatable, Sendable {
    /// 授权关联的媒体身份。
    public let mediaID: MediaID
    /// 不透明上传会话身份。
    public let uploadSessionID: MediaUploadSessionID
    /// 上传会话期限。
    public let expiresAt: Date
    /// 保存上传会话字段，不验证期限、授权或对象状态。
    public init(mediaID: MediaID, uploadSessionID: MediaUploadSessionID, expiresAt: Date) {
        self.mediaID = mediaID
        self.uploadSessionID = uploadSessionID
        self.expiresAt = expiresAt
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

/// 媒体服务返回的临时下载目标，URL 与请求头可能包含提供方凭证。
///
/// 不得写入消息、同步投影、本地发件箱、备份或日志。上传与下载使用不同类型，避免混用读写能力。
/// 合成 Codable 解码不执行普通构造器校验，消费响应时需单独验证。
public struct V2MediaDownloadTargetEnvelope: Codable, Equatable, Sendable {
    /// 完整 HTTPS 目标字符串，可能携带签名凭证。
    public let url: String
    /// 提供方要求的请求头，可能含敏感授权内容。
    public let headers: [String: String]
    /// 期限的 Unix 毫秒值，向下取整。
    public let expiresAtUnixMilliseconds: Int64
    /// 可选预期字节数，普通构造器要求非负。
    public let expectedByteCount: Int64?

    /// 构造临时目标并校验传输字段。
    ///
    /// - Parameters:
    ///   - url: HTTPS 地址，要求 host 非 nil，不额外排除用户信息、查询或片段。
    ///   - headers: 默认空；名称非空，名称与值不能含 ASCII 控制字符。
    ///   - expiresAt: 有限日期，转换后的向下取整 Unix 毫秒必须可表示为 Int64。
    ///   - expectedByteCount: 可选非负字节数。
    /// - Throws: 任一字段无效时抛出对应目标校验错误。
    ///
    /// 不要求期限晚于当前时钟，不验证完整 HTTP 头名语法或主机允许列表。
    public init(
        url: URL,
        headers: [String: String] = [:],
        expiresAt: Date,
        expectedByteCount: Int64? = nil
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              expiresAt.timeIntervalSince1970.isFinite,
              expectedByteCount.map({ $0 >= 0 }) ?? true,
              headers.allSatisfy({ name, value in
                  !name.isEmpty
                      && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
              })
        else { throw V2MediaValidationError.invalidDownloadTarget }

        let milliseconds = (expiresAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard let signedMilliseconds = Int64(exactly: milliseconds)
        else { throw V2MediaValidationError.invalidDownloadTarget }

        self.url = url.absoluteString
        self.headers = headers
        self.expiresAtUnixMilliseconds = signedMilliseconds
        self.expectedByteCount = expectedByteCount
    }

    /// 将保存的 Unix 毫秒期限转换为 Date，不执行到期判断。
    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtUnixMilliseconds) / 1_000)
    }
}

/// 媒体服务返回的临时上传目标，URL 与请求头可能包含提供方凭证。
///
/// 不得写入消息、同步投影、本地发件箱、备份或日志。上传与下载使用不同类型，避免混用读写能力。
/// 合成 Codable 解码不执行普通构造器校验，消费响应时需单独验证。
public struct V2MediaUploadTargetEnvelope: Codable, Equatable, Sendable {
    /// 完整 HTTPS 目标字符串，可能携带签名凭证。
    public let url: String
    /// 提供方要求的请求头，可能含敏感授权内容。
    public let headers: [String: String]
    /// 期限的 Unix 毫秒值，向下取整。
    public let expiresAtUnixMilliseconds: Int64
    /// 可选预期字节数，普通构造器要求非负。
    public let expectedByteCount: Int64?

    /// 构造临时目标并校验传输字段。
    ///
    /// - Parameters:
    ///   - url: HTTPS 地址，要求 host 非 nil，不额外排除用户信息、查询或片段。
    ///   - headers: 默认空；名称非空，名称与值不能含 ASCII 控制字符。
    ///   - expiresAt: 有限日期，转换后的向下取整 Unix 毫秒必须可表示为 Int64。
    ///   - expectedByteCount: 可选非负字节数。
    /// - Throws: 任一字段无效时抛出对应目标校验错误。
    ///
    /// 不要求期限晚于当前时钟，不验证完整 HTTP 头名语法或主机允许列表。
    public init(
        url: URL,
        headers: [String: String] = [:],
        expiresAt: Date,
        expectedByteCount: Int64? = nil
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              expiresAt.timeIntervalSince1970.isFinite,
              expectedByteCount.map({ $0 >= 0 }) ?? true,
              headers.allSatisfy({ name, value in
                  !name.isEmpty
                      && !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
                      && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
              })
        else { throw V2MediaValidationError.invalidUploadTarget }

        let milliseconds = (expiresAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard let signedMilliseconds = Int64(exactly: milliseconds)
        else { throw V2MediaValidationError.invalidUploadTarget }

        self.url = url.absoluteString
        self.headers = headers
        self.expiresAtUnixMilliseconds = signedMilliseconds
        self.expectedByteCount = expectedByteCount
    }

    /// 将保存的 Unix 毫秒期限转换为 Date，不执行到期判断。
    public var expiresAt: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAtUnixMilliseconds) / 1_000)
    }
}

/// 上传所有者轮询使用的临时生命周期响应，不包含对象地址、扫描诊断或其他用户信息。
public struct V2MediaUploadStatusEnvelope: Codable, Equatable, Sendable {
    /// 服务端返回的媒体生命周期状态。
    public let state: V2MediaObjectState

    /// 包装生命周期状态，不执行状态转换。
    public init(state: V2MediaObjectState) {
        self.state = state
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
    /// 临时上传目标字段无效。
    case invalidUploadTarget
    /// 持久展示资料字段无效。
    case invalidPresentation
}
