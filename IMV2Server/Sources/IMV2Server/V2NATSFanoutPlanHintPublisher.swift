import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// A non-authoritative wake hint. Consumers reload every durable fact from
/// PostgreSQL; a lost or duplicated hint cannot decide work completion.
public struct V2NATSFanoutPlanHint: Codable, Equatable, Sendable {
    public let sourceEventID: String
    public let planID: String

    public init(trigger: V2FanoutPlanTrigger) {
        sourceEventID = trigger.sourceEventID.rawValue
        planID = trigger.planID.rawValue
    }
}

public struct V2NATSFanoutHintConfiguration: Equatable, Sendable {
    public let url: URL
    public let subject: String
    public let token: String?

    public init(url: URL, subject: String, token: String? = nil) throws {
        guard url.scheme?.lowercased() == "nats", url.host != nil,
              subject.range(of: "^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil
        else { throw V2NATSFanoutHintConfigurationError.invalidConfiguration }
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken?.isEmpty != true else { throw V2NATSFanoutHintConfigurationError.invalidConfiguration }
        self.url = url
        self.subject = subject
        self.token = normalizedToken
    }
}

public enum V2NATSFanoutHintConfigurationError: Error, Equatable, Sendable { case invalidConfiguration }

public protocol V2FanoutPlanHintPublishing: Sendable {
    func publishHint(_ trigger: V2FanoutPlanTrigger) async throws
}

/// Minimal Core NATS CONNECT/PUB publisher built only on the runtime's NIO
/// dependencies. Each hint obtains a fresh connection, so a failed channel is
/// never retained. The surrounding durable wrapper intentionally ignores its
/// error after the PostgreSQL planner has completed.
public actor V2NATSFanoutPlanHintPublisher: V2FanoutPlanHintPublishing {
    private struct Connect: Encodable {
        let verbose = false
        let pedantic = false
        let token: String?
    }

    private let configuration: V2NATSFanoutHintConfiguration
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    public init(configuration: V2NATSFanoutHintConfiguration) { self.configuration = configuration }
    deinit { try? eventLoopGroup.syncShutdownGracefully() }

    public func publishHint(_ trigger: V2FanoutPlanTrigger) async throws {
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .connect(host: configuration.url.host!, port: configuration.url.port ?? 4222)
            .get()
        defer { channel.close(promise: nil) }
        let payload = try JSONEncoder().encode(V2NATSFanoutPlanHint(trigger: trigger))
        let connect = String(decoding: try JSONEncoder().encode(Connect(token: configuration.token)), as: UTF8.self)
        var buffer = channel.allocator.buffer(capacity: payload.count + connect.utf8.count + configuration.subject.utf8.count + 32)
        buffer.writeString("CONNECT \(connect)\r\nPUB \(configuration.subject) \(payload.count)\r\n")
        buffer.writeBytes(payload)
        buffer.writeString("\r\n")
        try await channel.writeAndFlush(buffer).get()
    }
}

public struct V2BestEffortFanoutPlanHintPublisher: V2FanoutPlanPublisher {
    private let durablePublisher: any V2FanoutPlanPublisher
    private let hintPublisher: any V2FanoutPlanHintPublishing

    public init(durablePublisher: any V2FanoutPlanPublisher, hintPublisher: any V2FanoutPlanHintPublishing) {
        self.durablePublisher = durablePublisher
        self.hintPublisher = hintPublisher
    }

    public func publish(_ trigger: V2FanoutPlanTrigger) async throws {
        try await durablePublisher.publish(trigger)
        try? await hintPublisher.publishHint(trigger)
    }
}
