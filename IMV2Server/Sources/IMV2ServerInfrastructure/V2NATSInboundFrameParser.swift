import IMV2ServerApplication
import IMV2ServerContracts
import Foundation

/// 可选唤醒代理共用的 Core NATS 帧解析状态，限定在单个事件循环内使用。
///
/// 执行边界由调用方负责：该值必须存放在 `NIOLoopBoundBox` 中，
/// 绝不能直接跨越到 actor 或任务。
struct V2NATSInboundFrameParser {
    /// 默认允许的单条载荷字节上限。
    static let defaultMaximumPayloadBytes = 16 * 1_024
    /// 单条载荷的绝对上限，超过即视为协议异常。
    static let absoluteMaximumPayloadBytes = 1_024 * 1_024
    private static let maximumOutputsPerRead = 256

    /// 非法消息的处置策略。
    enum InvalidMessagePolicy: Sendable {
        /// 关闭连接。
        ///
        /// 畸形的 `MSG` 声明意味着房间唤醒流已经不合法，关闭连接可以让重连与恢复显式发生。
        case closeChannel
        /// 忽略该条声明。
        ///
        /// 实时活动提示本身允许丢失，忽略非法声明并保留连接，以便继续接收后续合法提示。
        case ignore
    }

    /// 解析结果。
    enum Output: Sendable {
        /// 收到一条完整载荷。
        case payload(subject: String, payload: Data)
        /// 代理请求保活响应。
        case ping
        /// 确认代理已解析本端 PING 之前的全部命令。
        case pong
        /// 代理返回错误响应。
        case brokerError
        /// 需要关闭连接。
        case closeChannel
    }

    private var pending = Data()
    private var remainingPayloadBytes: Int?
    private var pendingPayloadSubject: String?
    private let invalidMessagePolicy: InvalidMessagePolicy
    private let maximumPayloadBytes: Int
    private let maximumBufferedBytes: Int

    /// 构造解析器。
    ///
    /// 缓冲上限取默认下限 64 KiB 与「四帧加 1 KiB」中的较大值：一次 NIO 读取可能合并多条合法消息，
    /// 因此既要有界，又不能把合法的合并读取误判为超长载荷。
    ///
    /// - Parameters:
    ///   - invalidMessagePolicy: 非法消息处置策略。
    ///   - maximumPayloadBytes: 单条载荷上限，需大于零且不超过绝对上限。
    init(
        invalidMessagePolicy: InvalidMessagePolicy,
        maximumPayloadBytes: Int = Self.defaultMaximumPayloadBytes
    ) {
        precondition(
            maximumPayloadBytes > 0
                && maximumPayloadBytes <= Self.absoluteMaximumPayloadBytes
        )
        self.invalidMessagePolicy = invalidMessagePolicy
        self.maximumPayloadBytes = maximumPayloadBytes
        // 一次 NIO 读取可能合并多条完整 NATS 消息。
        // 限制解析器的总分配量，同时允许消费四个合法帧，
        // 不把它们合并后的读取误判为单条过大的载荷。
        maximumBufferedBytes = max(
            64 * 1_024,
            maximumPayloadBytes * 4 + 1_024
        )
    }

    /// 消费一段网络字节并产出解析结果。
    ///
    /// 缓冲超限、单条载荷超过上限、载荷结束符不匹配或单次读取产出过多时会清空缓冲并请求关闭连接；
    /// 合法状态下则逐行解析控制指令与消息头，并把完整载荷按到达顺序输出。
    ///
    /// - Parameter bytes: 本次读取到的字节。
    /// - Returns: 本次解析出的全部输出。
    mutating func consume(_ bytes: Data) -> [Output] {
        pending.append(bytes)
        guard pending.count <= maximumBufferedBytes else {
            pending.removeAll(keepingCapacity: false)
            remainingPayloadBytes = nil
            pendingPayloadSubject = nil
            return [.closeChannel]
        }
        var outputs: [Output] = []
        var consumedBytes = 0
        // 一次网络读取可能包含数百条 NATS 控制行和消息。
        // 推进游标并只压缩一次，可避免 Data 反复移动前缀，
        // 使处理开销随数据量呈平方增长。
        defer {
            if consumedBytes > 0, consumedBytes <= pending.count {
                pending.removeFirst(consumedBytes)
            }
        }

        while true {
            guard outputs.count < Self.maximumOutputsPerRead else {
                pending.removeAll(keepingCapacity: false)
                remainingPayloadBytes = nil
                pendingPayloadSubject = nil
                consumedBytes = 0
                outputs.append(.closeChannel)
                return outputs
            }
            let available = pending.dropFirst(consumedBytes)
            if let remainingPayloadBytes {
                guard available.count >= remainingPayloadBytes + 2 else { return outputs }
                let payload = Data(available.prefix(remainingPayloadBytes))
                guard let subject = pendingPayloadSubject,
                      available.dropFirst(remainingPayloadBytes).starts(with: [13, 10]) else {
                    pending.removeAll(keepingCapacity: false)
                    self.remainingPayloadBytes = nil
                    pendingPayloadSubject = nil
                    consumedBytes = 0
                    outputs.append(.closeChannel)
                    return outputs
                }
                consumedBytes += remainingPayloadBytes + 2
                self.remainingPayloadBytes = nil
                pendingPayloadSubject = nil
                outputs.append(.payload(subject: subject, payload: payload))
                continue
            }

            guard let range = available.range(of: Data([13, 10])) else { return outputs }
            let line = String(decoding: available[..<range.lowerBound], as: UTF8.self)
            consumedBytes += available.distance(from: available.startIndex, to: range.upperBound)
            if line == "PING" {
                outputs.append(.ping)
                continue
            }
            if line == "PONG" {
                outputs.append(.pong)
                continue
            }
            if line.hasPrefix("-ERR") {
                outputs.append(.brokerError)
                continue
            }
            guard line.hasPrefix("MSG ") else { continue }
            let parts = line.split(separator: " ")
            guard (parts.count == 4 || parts.count == 5),
                  let subject = validSubject(String(parts[1])),
                  let countText = parts.last,
                  let count = Int(countText), count >= 0 else {
                if invalidMessagePolicy == .closeChannel {
                    outputs.append(.closeChannel)
                    return outputs
                }
                continue
            }
            guard count <= maximumPayloadBytes else {
                pending.removeAll(keepingCapacity: false)
                pendingPayloadSubject = nil
                consumedBytes = 0
                outputs.append(.closeChannel)
                return outputs
            }
            pendingPayloadSubject = subject
            remainingPayloadBytes = count
        }
    }

    /// 校验并返回合法的 NATS 主题。
    ///
    /// 主题长度需在 1 至 512 字节之间，由 `.` 分隔的非空段组成，
    /// 段内字符限为字母、数字、`-` 与 `_`。
    ///
    /// - Parameter value: 待校验主题。
    /// - Returns: 合法主题；否则为 `nil`。
    private func validSubject(_ value: String) -> String? {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 512 else { return nil }
        var segmentLength = 0
        for byte in bytes {
            if byte == 46 { // `.`
                guard segmentLength > 0 else { return nil }
                segmentLength = 0
                continue
            }
            let isAllowed = (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45 // `-`
                || byte == 95 // `_`
            guard isAllowed else { return nil }
            segmentLength += 1
        }
        guard segmentLength > 0 else { return nil }
        return value
    }
}

/// 载荷提交接口。
///
/// 一次 NIO 读取可能带来大量代理消息。这里用单条有界异步流承担跨界跳转，
/// 在保持顺序的同时不必为每条载荷派生一个游离任务。这些提示不具备权威性，
/// 因此过载时只保留较新的载荷，持久化同步仍是恢复来源。
protocol V2NATSPayloadSubmitting: Sendable {
    /// 提交一条载荷。
    ///
    /// - Parameters:
    ///   - subject: 消息主题。
    ///   - payload: 消息载荷。
    func submit(subject: String, payload: Data)
}

/// 以有界异步流串行转发载荷的提交器。
final class V2NATSPayloadDispatcher: V2NATSPayloadSubmitting, Sendable {
    private struct Submission: Sendable {
        let subject: String
        let payload: Data
    }

    private let continuation: AsyncStream<Submission>.Continuation
    private let worker: Task<Void, Never>

    /// 构造提交器并启动消费任务。
    ///
    /// 缓冲策略为保留最新若干条：溢出时丢弃较旧载荷而不阻塞读取端。
    ///
    /// - Parameters:
    ///   - capacity: 流缓冲上限，需大于零。
    ///   - onPayload: 逐条异步处理载荷的闭包。
    init(
        capacity: Int = 256,
        onPayload: @escaping @Sendable (String, Data) async -> Void
    ) {
        precondition(capacity > 0)
        let (stream, continuation) = AsyncStream<Submission>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        self.continuation = continuation
        worker = Task {
            for await submission in stream {
                guard !Task.isCancelled else { break }
                await onPayload(submission.subject, submission.payload)
            }
        }
    }

    /// 提交一条载荷到内部流。
    ///
    /// - Parameters:
    ///   - subject: 消息主题。
    ///   - payload: 消息载荷。
    func submit(subject: String, payload: Data) {
        continuation.yield(.init(subject: subject, payload: payload))
    }

    /// 结束流并取消消费任务，避免析构后残留任务。
    deinit {
        continuation.finish()
        worker.cancel()
    }
}
