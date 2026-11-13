import Foundation
import IMV2Core
/// 实时连接的主机与端口配置；不包含凭证或自定义信任策略。
public struct V2RealtimeEndpoint: Equatable, Sendable {
    /// 原样保存的主机字符串，初始化只检查去除首尾空白后非空。
    public let host: String
    /// 非零目标端口。
    public let port: UInt16

    /// 创建实时连接端点。
    ///
    /// - Parameters:
    ///   - host: 非空主机，检查时去除首尾空白但保存原值。
    ///   - port: 非零端口。
    /// - Throws: 空主机或零端口时抛出 invalidEndpoint。
    ///
    /// 不在此解析 DNS、验证地址语法或建立网络连接。
    public init(host: String, port: UInt16) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port > 0 else {
            throw V2TLSFrameConnectionError.invalidEndpoint
        }
        self.host = host
        self.port = port
    }
}

/// 连接配置、握手、请求关联和提示消费的错误分类。
public enum V2TLSFrameConnectionError: Error, Equatable, Sendable {
    /// 主机为空或端口为零。
    case invalidEndpoint
    /// 未建立可用于当前操作的已认证连接。
    case notConnected
    /// 底层连接启动失败。
    case connectionFailed
    /// 连接关闭或操作所属连接代际已失效。
    case connectionClosed
    /// 关联请求在期限内未收到响应。
    case requestTimedOut
    /// 握手版本不在允许范围。
    case unsupportedVersion
    /// 认证未成功。
    case authenticationFailed
    /// 握手响应或协商字段不满足要求。
    case invalidHandshake
    /// 压缩协商不受支持。
    case unsupportedCompression
    /// 帧标志与连接合同不符。
    case unsupportedFrameFlags
    /// 响应类型、关联或内容不符合预期。
    case unexpectedResponse
    /// 同类提示已有等待者，不允许另一个并发消费者。
    case concurrentAvailabilityConsumer
    /// 在途请求达到连接预算。
    case tooManyPendingRequests
}

/// 可注入的异步字节连接边界。
///
/// 生产实现使用 TLS 1.3 与平台信任校验，测试实现可控制旧连接回调时机。此接口不解析 IM 帧或认证载荷。
public protocol V2TLSByteConnection: Sendable {
    /// 启动连接并等待可发送字节；连接失败通过错误报告。
    func start() async throws
    /// 发送字节并等待底层完成回调，不代表服务端业务已确认。
    func send(_ data: Data) async throws
    /// 读取不超过请求上限的一段字节，不保证包含完整协议帧。
    func receive(maximumLength: Int) async throws -> Data
    /// 请求终止底层连接，不要求同步等待所有回调结束。
    func cancel()
}


public enum V2SystemTLSByteConnection {
    public static func make(endpoint: V2RealtimeEndpoint) -> any V2TLSByteConnection {
        #if canImport(Network) && canImport(Security)
        V2NetworkTLSByteConnection(endpoint: endpoint)
        #else
        V2UnavailableTLSByteConnection()
        #endif
    }
}
private struct V2UnavailableTLSByteConnection: V2TLSByteConnection {
    func start() async throws { throw V2TLSFrameConnectionError.notConnected }
    func send(_: Data) async throws { throw V2TLSFrameConnectionError.notConnected }
    func receive(maximumLength: Int) async throws -> Data { throw V2TLSFrameConnectionError.notConnected }
    func cancel() {}
}
