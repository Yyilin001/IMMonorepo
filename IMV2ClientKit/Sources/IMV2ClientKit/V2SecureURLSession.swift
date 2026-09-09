import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 账户与签名媒体请求使用的隔离 URLSession 工厂及共享连接池。
///
/// 禁用 Cookie、URL 凭证存储与 URL 缓存，并拒绝自动重定向，避免请求体或授权头被转发到 Location 指定的地址。
public enum V2SecureURLSession {
    /// 账户服务适配器共享的连接池，在保持存储隔离的同时允许连接及 TLS 会话复用。
    public static let account = make()

    /// 独立的媒体提供方连接池，将签名媒体请求与账户服务请求分离。
    public static let mediaProvider = make()

    /// 创建临时配置的 URLSession，禁用 Cookie 接收、Cookie 存储、URL 凭证存储和 URL 缓存。
    ///
    /// - Returns: 使用拒绝重定向代理的新会话；共享池由静态属性持有，自建会话生命周期由调用方管理。
    ///
    /// 此工厂不限制请求 URL，业务适配器仍负责自己的端点校验。
    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: V2RejectingRedirectDelegate.shared,
            delegateQueue: nil
        )
    }
}

/// 无可变成员的共享重定向代理，以 @unchecked Sendable 接入 URLSession 回调边界。
final class V2RejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// 所有隔离会话共用的无状态代理实例。
    static let shared = V2RejectingRedirectDelegate()

    /// 对每次 HTTP 重定向回调返回 nil，停止自动跟随，交由请求调用方处理原响应。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Authentication bodies and provider authorization headers must never
        // be replayed to a Location selected by an intermediary.
        completionHandler(nil)
    }
}

/// HTTP 适配器共享的响应格式判断。
enum V2HTTPContract {
    /// 读取 Content-Type，去除首个分号后的参数、首尾空白并转为小写。
    ///
    /// - Returns: 值为 application/json 或以 +json 结尾时为 true，缺失或其他类型为 false。
    ///
    /// 仅执行字符串判断，不验证媒体类型完整语法，也不解析响应体。
    static func isJSON(_ response: HTTPURLResponse) -> Bool {
        guard let raw = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return raw == "application/json" || raw.hasSuffix("+json")
    }
}
