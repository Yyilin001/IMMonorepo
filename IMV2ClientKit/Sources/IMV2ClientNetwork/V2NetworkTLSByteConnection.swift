import Foundation
import IMV2ClientPlatform
#if canImport(Network) && canImport(Security)
import Network
import Security
/// 把 Network.framework 回调桥接为异步字节读写。
///
/// 端点构造路径限定 TLS 1.3，沿用平台信任校验；内部连接注入路径由调用者提供正确配置。
/// 异步方法不自行安装 Task 取消处理器，连接所有者通过 cancel 终止底层连接。
public struct V2NetworkTLSByteConnection: V2TLSByteConnection {
    /// 底层网络连接，生产端点路径配置了 TLS 1.3。
    let connection: NWConnection
    /// 用于启动连接及接收网络回调的队列。
    private let queue: DispatchQueue
    /// 按端点创建仅允许 TLS 1.3 的 TCP 连接，使用平台默认信任验证与 utility 队列；不立即启动连接。
    public init(endpoint: V2RealtimeEndpoint) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let parameters = NWParameters(tls: tls, tcp: .init())
        connection = NWConnection(host: .init(endpoint.host), port: .init(rawValue: endpoint.port)!, using: parameters)
        queue = .global(qos: .utility)
    }
    // Internal byte-boundary injection for Network.framework callback tests.
    // The public endpoint initializer above always configures validated TLS.
    /// 注入已配置的连接与队列以支持回调测试；此初始化方法不重新配置 TLS 或验证其参数。
    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }
    /// 启动连接并等待 ready，failed 或 cancelled 映射为 connectionFailed。
    ///
    /// 使用互斥保护的可选 continuation 保证完成一次；已排队的后续状态回调不能重复恢复等待者。
    /// waiting 等中间状态继续等待，本层不设置启动超时。
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = V2Lock<CheckedContinuation<Void, Error>?>(initialState: continuation)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready: result = .success(())
                case .failed, .cancelled: result = .failure(V2TLSFrameConnectionError.connectionFailed)
                default: return
                }
                // Framework state callbacks can already be queued when the
                // handler is cleared. Complete this readiness bridge once.
                let waiter = pending.withLock { value in
                    let waiter = value
                    value = nil
                    return waiter
                }
                connection.stateUpdateHandler = nil
                waiter?.resume(with: result)
            }
            connection.start(queue: queue)
        }
    }
    /// 等待 contentProcessed 回调，非空错误映射为 connectionFailed。
    ///
    /// 成功仅表示底层发送处理完成，不表示对端应用收到或事务提交。Task 取消本身不会在本方法中主动取消网络连接。
    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
            })
        }
    }
    /// 请求至少一个、不超过上限的字节片段。
    ///
    /// - Parameter maximumLength: 交给 Network.framework 的读取上限，此处不另行验证。
    /// - Returns: 非空字节片段；分帧与跨读取缓冲由上层处理。
    /// - Throws: 回调错误映射为 connectionFailed，无错误但没有非空字节时映射为 connectionClosed。
    ///
    /// 若回调同时标记流结束并带有字节，此方法仍先返回字节，不独立报告结束标志。
    public func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { bytes, _, _, error in
                if error != nil { continuation.resume(throwing: V2TLSFrameConnectionError.connectionFailed) }
                else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: V2TLSFrameConnectionError.connectionClosed) }
            }
        }
    }
    /// 调用底层连接取消，不等待取消回调，也不直接处理上层请求关联状态。
    public func cancel() { connection.cancel() }
}


#endif
