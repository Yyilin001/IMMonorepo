import Foundation

/// Event-loop-confined Core NATS framing state shared by the optional wake
/// brokers. Callers own the execution boundary: this value must live inside a
/// `NIOLoopBoundBox` and never cross to an actor or task directly.
struct V2NATSInboundFrameParser {
    enum InvalidMessagePolicy: Sendable {
        /// A malformed `MSG` declaration indicates an invalid room-wake
        /// stream, so closing makes reconnect/recovery explicit.
        case closeChannel
        /// Live-activity hints are lossy. Ignore an invalid declaration and
        /// retain the connection for later valid hints.
        case ignore
    }

    enum Output: Sendable {
        case payload(Data)
        case pong
        case closeChannel
    }

    private var pending = Data()
    private var remainingPayloadBytes: Int?
    private let invalidMessagePolicy: InvalidMessagePolicy

    init(invalidMessagePolicy: InvalidMessagePolicy) {
        self.invalidMessagePolicy = invalidMessagePolicy
    }

    mutating func consume(_ bytes: Data) -> [Output] {
        pending.append(bytes)
        var outputs: [Output] = []

        while true {
            if let remainingPayloadBytes {
                guard pending.count >= remainingPayloadBytes + 2 else { return outputs }
                let payload = Data(pending.prefix(remainingPayloadBytes))
                guard pending.dropFirst(remainingPayloadBytes).starts(with: [13, 10]) else {
                    pending.removeAll(keepingCapacity: false)
                    self.remainingPayloadBytes = nil
                    outputs.append(.closeChannel)
                    return outputs
                }
                pending.removeFirst(remainingPayloadBytes + 2)
                self.remainingPayloadBytes = nil
                outputs.append(.payload(payload))
                continue
            }

            guard let range = pending.range(of: Data([13, 10])) else { return outputs }
            let line = String(decoding: pending[..<range.lowerBound], as: UTF8.self)
            pending.removeFirst(range.upperBound)
            if line == "PING" {
                outputs.append(.pong)
                continue
            }
            guard line.hasPrefix("MSG ") else { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 4, let count = Int(parts[3]), count >= 0 else {
                if invalidMessagePolicy == .closeChannel {
                    outputs.append(.closeChannel)
                    return outputs
                }
                continue
            }
            remainingPayloadBytes = count
        }
    }
}
