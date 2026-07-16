import Vapor

struct IMDeliveryTraceSamplingConfiguration: Sendable {
    let enabled: Bool
    let sampleRateBasisPoints: Int
    let maxLogsPerMinute: Int

    var isEnabled: Bool {
        enabled && sampleRateBasisPoints > 0 && maxLogsPerMinute > 0
    }

    static func load(from environment: Environment) -> IMDeliveryTraceSamplingConfiguration {
        let enabled = Environment.get("IM_DELIVERY_TRACE_SAMPLING_ENABLED")
            .map { ["1", "true", "yes", "on"].contains($0.lowercased()) }
            ?? false
        return IMDeliveryTraceSamplingConfiguration(
            enabled: enabled,
            sampleRateBasisPoints: min(
                10_000,
                max(0, Environment.get("IM_DELIVERY_TRACE_SAMPLE_RATE_BPS").flatMap(Int.init(_:)) ?? 100)
            ),
            maxLogsPerMinute: min(
                10_000,
                max(0, Environment.get("IM_DELIVERY_TRACE_MAX_LOGS_PER_MINUTE").flatMap(Int.init(_:)) ?? 60)
            )
        )
    }
}

actor IMDeliveryTraceSampler {
    private var activeMinute: Int?
    private var emittedInActiveMinute = 0

    func shouldSample(
        _ trace: IMDeliveryTrace,
        configuration: IMDeliveryTraceSamplingConfiguration,
        now: Date = Date()
    ) -> Bool {
        guard configuration.isEnabled,
              Self.sampleBucket(for: trace) < configuration.sampleRateBasisPoints
        else {
            return false
        }

        let minute = Int(now.timeIntervalSince1970 / 60)
        if activeMinute != minute {
            activeMinute = minute
            emittedInActiveMinute = 0
        }
        guard emittedInActiveMinute < configuration.maxLogsPerMinute else {
            return false
        }
        emittedInActiveMinute += 1
        return true
    }

    private static func sampleBucket(for trace: IMDeliveryTrace) -> Int {
        let stableKey = [
            trace.conversationID.uuidString,
            trace.eventID?.uuidString ?? "",
            trace.requestID?.uuidString ?? ""
        ].joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % 10_000)
    }
}

private struct IMDeliveryTraceSamplingConfigurationStorageKey: StorageKey {
    typealias Value = IMDeliveryTraceSamplingConfiguration
}

private struct IMDeliveryTraceSamplerStorageKey: StorageKey {
    typealias Value = IMDeliveryTraceSampler
}

extension Application {
    var deliveryTraceSamplingConfiguration: IMDeliveryTraceSamplingConfiguration {
        get {
            if let configuration = storage[IMDeliveryTraceSamplingConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = IMDeliveryTraceSamplingConfiguration.load(from: environment)
            storage[IMDeliveryTraceSamplingConfigurationStorageKey.self] = configuration
            return configuration
        }
        set { storage[IMDeliveryTraceSamplingConfigurationStorageKey.self] = newValue }
    }

    var deliveryTraceSampler: IMDeliveryTraceSampler {
        get {
            if let sampler = storage[IMDeliveryTraceSamplerStorageKey.self] {
                return sampler
            }
            let sampler = IMDeliveryTraceSampler()
            storage[IMDeliveryTraceSamplerStorageKey.self] = sampler
            return sampler
        }
        set { storage[IMDeliveryTraceSamplerStorageKey.self] = newValue }
    }
}

struct IMDeliveryTrace: Sendable {
    let conversationID: UUID
    let eventID: UUID?
    let requestID: UUID?
    let clientMessageID: String?
    let runtimeRole: String?
    let timelineSequence: UInt64?
    let ownerSequence: UInt64?

    init(
        conversationID: UUID,
        eventID: UUID? = nil,
        requestID: UUID? = nil,
        clientMessageID: String? = nil,
        runtimeRole: String? = nil,
        timelineSequence: UInt64? = nil,
        ownerSequence: UInt64? = nil
    ) {
        self.conversationID = conversationID
        self.eventID = eventID
        self.requestID = requestID
        let normalizedClientMessageID = clientMessageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientMessageID = normalizedClientMessageID?.isEmpty == false ? normalizedClientMessageID : nil
        let normalizedRuntimeRole = runtimeRole?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runtimeRole = normalizedRuntimeRole?.isEmpty == false ? normalizedRuntimeRole : nil
        self.timelineSequence = timelineSequence
        self.ownerSequence = ownerSequence
    }

    func fields(outcome: String) -> [String: String] {
        var fields = [
            "conversation_id": conversationID.uuidString,
            "outcome": outcome
        ]
        if let eventID {
            fields["event_id"] = eventID.uuidString
        }
        if let requestID {
            fields["request_id"] = requestID.uuidString
        }
        if let clientMessageID {
            fields["client_message_id"] = clientMessageID
        }
        if let runtimeRole {
            fields["runtime_role"] = runtimeRole
        }
        if let timelineSequence {
            fields["timeline_sequence"] = String(timelineSequence)
        }
        if let ownerSequence {
            fields["owner_sequence"] = String(ownerSequence)
        }
        return fields
    }

    func metadata(outcome: String) -> Logger.Metadata {
        fields(outcome: outcome).reduce(into: Logger.Metadata()) { metadata, field in
            metadata[field.key] = .string(field.value)
        }
    }
}

func imDeliveryFailureMetadata(
    trace: IMDeliveryTrace?,
    runtimeRole: String,
    outcome: String = "failed",
    errorKind: String
) -> Logger.Metadata {
    var metadata = trace?.metadata(outcome: outcome) ?? [
        "runtime_role": .string(runtimeRole),
        "outcome": .string(outcome)
    ]
    metadata["error_kind"] = .string(errorKind)
    return metadata
}

func imLogSampledDeliveryTrace(
    app: Application,
    trace: IMDeliveryTrace,
    stage: String,
    additionalMetadata: Logger.Metadata = [:]
) async {
    guard await app.deliveryTraceSampler.shouldSample(
        trace,
        configuration: app.deliveryTraceSamplingConfiguration
    ) else {
        return
    }

    var metadata = trace.metadata(outcome: "sampled")
    metadata["trace_stage"] = .string(stage)
    for (key, value) in additionalMetadata {
        metadata[key] = value
    }
    app.logger.info("IM delivery trace", metadata: metadata)
}

final class IMMessagePersistenceDiagnostics: @unchecked Sendable {
    private let startedAt = Date()
    private let lock = NSLock()
    private var marks: [String: Int] = [:]
    private var recipientCount = 0

    func measure<T>(
        _ name: String,
        operation: () async throws -> T
    ) async throws -> T {
        let startedAt = Date()
        let result = try await operation()
        record(name, startedAt: startedAt)
        return result
    }

    func record(_ name: String, startedAt: Date) {
        lock.lock()
        marks[name, default: 0] += max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        lock.unlock()
    }

    func recordRecipientCount(_ value: Int) {
        lock.lock()
        recipientCount = max(recipientCount, value)
        lock.unlock()
    }

    func capturedMarks() -> [String: Int] {
        lock.lock()
        let captured = marks
        lock.unlock()
        return captured
    }

    func capturedRecipientCount() -> Int {
        lock.lock()
        let captured = recipientCount
        lock.unlock()
        return captured
    }

    func totalMilliseconds() -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }

    func logIfSlow(
        app: Application?,
        trace: IMDeliveryTrace,
        messageCount: Int
    ) {
        guard let app else {
            return
        }
        let totalMillis = totalMilliseconds()
        let threshold = max(
            0,
            Environment.get("IM_MESSAGE_PERSISTENCE_SLOW_LOG_MS").flatMap(Int.init(_:)) ?? 1_000
        )
        guard threshold == 0 || totalMillis >= threshold else {
            return
        }

        lock.lock()
        let capturedMarks = marks
        let capturedRecipientCount = recipientCount
        lock.unlock()

        var metadata = trace.metadata(outcome: "slow")
        metadata["message_count"] = .stringConvertible(messageCount)
        metadata["recipient_count"] = .stringConvertible(capturedRecipientCount)
        metadata["total_ms"] = .stringConvertible(totalMillis)
        for (name, millis) in capturedMarks.sorted(by: { $0.key < $1.key }) {
            metadata["\(name)_ms"] = .stringConvertible(millis)
        }
        app.logger.warning("IM message persistence slow", metadata: metadata)
    }
}
