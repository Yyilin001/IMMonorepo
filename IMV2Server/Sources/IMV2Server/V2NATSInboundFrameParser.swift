import Foundation

/// Event-loop-confined Core NATS framing state shared by the optional wake
/// brokers. Callers own the execution boundary: this value must live inside a
/// `NIOLoopBoundBox` and never cross to an actor or task directly.
struct V2NATSInboundFrameParser {
    static let defaultMaximumPayloadBytes = 16 * 1_024
    static let absoluteMaximumPayloadBytes = 1_024 * 1_024
    private static let maximumOutputsPerRead = 256
    enum InvalidMessagePolicy: Sendable {
        /// A malformed `MSG` declaration indicates an invalid room-wake
        /// stream, so closing makes reconnect/recovery explicit.
        case closeChannel
        /// Live-activity hints are lossy. Ignore an invalid declaration and
        /// retain the connection for later valid hints.
        case ignore
    }

    enum Output: Sendable {
        case payload(subject: String, payload: Data)
        /// The broker requests a keepalive response from this client.
        case ping
        /// Confirms that the broker parsed every command preceding our PING.
        case pong
        case brokerError
        case closeChannel
    }

    private var pending = Data()
    private var remainingPayloadBytes: Int?
    private var pendingPayloadSubject: String?
    private let invalidMessagePolicy: InvalidMessagePolicy
    private let maximumPayloadBytes: Int
    private let maximumBufferedBytes: Int

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
        // A NIO read may coalesce several complete NATS messages. Bound the
        // aggregate parser allocation while allowing four legal frames to be
        // consumed without falsely treating their combined read as one
        // oversized payload.
        maximumBufferedBytes = max(
            64 * 1_024,
            maximumPayloadBytes * 4 + 1_024
        )
    }

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
        // One network read may contain hundreds of NATS control lines and
        // messages. Advancing a cursor and compacting once avoids Data's
        // repeated prefix shift turning that read into quadratic copying.
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

/// NIO can deliver many broker messages in one read. A single bounded stream
/// owns the async hop, preserving order without spawning one unstructured Task
/// per payload. These hints are non-authoritative, so overload coalesces old
/// payloads and durable sync remains the recovery source.
protocol V2NATSPayloadSubmitting: Sendable {
    func submit(subject: String, payload: Data)
}

final class V2NATSPayloadDispatcher: V2NATSPayloadSubmitting, Sendable {
    private struct Submission: Sendable {
        let subject: String
        let payload: Data
    }

    private let continuation: AsyncStream<Submission>.Continuation
    private let worker: Task<Void, Never>

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

    func submit(subject: String, payload: Data) {
        continuation.yield(.init(subject: subject, payload: payload))
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }
}
