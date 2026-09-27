import Foundation
import IMV2Core

/// 本地暂存上传的内部目标。
///
/// 该值只会从已认证的媒体边缘返回给请求设备。它刻意不实现 `Codable`，
/// 也绝不能进入聊天事件、日志字段、推送载荷或数据库记录。
public struct V2MediaProviderUploadTarget: Equatable, Sendable {
    /// 提供方签发的访问地址。
    public let url: URL
    /// 访问该地址需要携带的请求头。
    public let headers: [String: String]
    /// 目标到期时刻。
    public let expiresAt: Date
    /// 期望的字节数；未知时为 `nil`。
    public let expectedByteCount: Int64?

    /// 保存提供方对象目标。
    ///
    /// - Parameters:
    ///   - url: 访问地址。
    ///   - headers: 附加请求头，默认空。
    ///   - expiresAt: 到期时刻。
    ///   - expectedByteCount: 期望字节数，默认未知。
    public init(url: URL, headers: [String: String] = [:], expiresAt: Date, expectedByteCount: Int64? = nil) {
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
        self.expectedByteCount = expectedByteCount
    }
}

/// 提供方签发单个短时上传目标的能力。
///
/// 该能力与下载能力刻意分离，避免部署时误把写权限授予仅支持下载的适配器。
public protocol V2MediaUploadObjectProvider: Sendable {
    /// 为指定媒体签发上传目标。
    ///
    /// - Parameters:
    ///   - mediaID: 目标媒体标识。
    ///   - contentType: 媒体内容类型。
    ///   - byteCount: 期望上传字节数。
    ///   - expiresAt: 目标到期时刻。
    /// - Returns: 提供方对象目标。
    /// - Throws: 提供方失败时抛出。
    func issueUploadTarget(
        mediaID: MediaID,
        contentType: String,
        byteCount: Int64,
        expiresAt: Date
    ) async throws -> V2MediaProviderUploadTarget
}
