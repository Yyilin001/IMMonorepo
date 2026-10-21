import Foundation

/// Optional benchmark payload metadata. A shared Linux boot ID identifies the
/// monotonic clock domain; different hosts must never silently compare uptimes.
public struct V2LoadVisibilityStamp: Equatable, Sendable {
    public let clockDomain: UUID
    public let runID: UUID
    public let scheduledNanoseconds: UInt64
    public let cohort: String

    public init?(clockDomain: UUID, runID: UUID, scheduledNanoseconds: UInt64, cohort: String) {
        guard scheduledNanoseconds > 0, !cohort.isEmpty, cohort.utf8.count <= 32,
              cohort.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        self.clockDomain = clockDomain
        self.runID = runID
        self.scheduledNanoseconds = scheduledNanoseconds
        self.cohort = cohort
    }

    /// Keeps the requested UTF-8 message size exactly; no extra side channel.
    public func text(byteCount: Int) -> String? {
        let domain = clockDomain.uuidString.replacingOccurrences(of: "-", with: "")
        let run = runID.uuidString.replacingOccurrences(of: "-", with: "")
        let header = "IMV2LAT1|\(domain)|\(run)|\(String(scheduledNanoseconds, radix: 16))|\(cohort)|"
        guard byteCount >= header.utf8.count else { return nil }
        return header + String(repeating: "x", count: byteCount - header.utf8.count)
    }

    public init?(text: String) {
        let parts = text.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "IMV2LAT1", parts[5].utf8.allSatisfy({ $0 == 120 }),
              let domain = Self.uuid(parts[1]), let run = Self.uuid(parts[2]),
              let scheduled = UInt64(parts[3], radix: 16) else { return nil }
        self.init(clockDomain: domain, runID: run, scheduledNanoseconds: scheduled, cohort: String(parts[4]))
    }

    /// Uses the received message body, not its availability hint or server H.
    /// Own sends are excluded: local ACK/echo is not peer-visible delivery.
    public static func fromMessagePayload(_ data: Data, roomID: String, sequence: UInt64,
                                          excludingSender: String) -> Self? {
        struct Body: Decodable {
            let event_type: String
            let room_id: String
            let room_sequence: UInt64
            let sender_user_id: String
            let text: String
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              body.event_type == "message.accepted", body.room_sequence == sequence,
              let room = UUID(uuidString: roomID), UUID(uuidString: body.room_id) == room,
              let sender = UUID(uuidString: body.sender_user_id),
              let own = UUID(uuidString: excludingSender), sender != own else { return nil }
        return .init(text: body.text)
    }

    private static func uuid(_ compact: Substring) -> UUID? {
        guard compact.utf8.count == 32, compact.utf8.allSatisfy({ (48...57).contains($0) ||
            (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let characters = Array(compact)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return UUID(uuidString: groups.map { String(characters[$0]) }.joined(separator: "-"))
    }
}

/// Observes bodies without changing recovery targets or the application cursor.
/// The caller supplies its independently validated contiguous applied cursor.
public struct V2LoadVisibilityObservation: Sendable {
    public enum BodySource: String, Equatable, Sendable, Encodable {
        case realtimePush
        case recoveryPage
    }
    public enum RememberResult: Equatable, Sendable {
        case remembered, duplicate, alreadyApplied, foreignRun, foreignClock, capacityExceeded, conflictingBody
    }
    public struct Sample: Equatable, Sendable, Encodable {
        public let cohort: String
        public let sequence: UInt64
        public let scheduledNanoseconds: UInt64
        public let receivedNanoseconds: UInt64
        public let bodySource: BodySource
        public let appliedNanoseconds: UInt64
        public let milliseconds: Double
        public let bodyArrivalMilliseconds: Double
        public let contiguousApplicationWaitMilliseconds: Double
    }
    public struct Applied: Equatable, Sendable {
        public let samples: [Sample]
        public let invalidClockSamples: Int
    }
    private let clockDomain: UUID
    private let runID: UUID
    private let maximumPending: Int
    private struct Pending: Sendable {
        let stamp: V2LoadVisibilityStamp
        let receivedNanoseconds: UInt64
        let bodySource: BodySource
    }
    private var pending: [UInt64: Pending] = [:]
    public var pendingCount: Int { pending.count }

    public init(clockDomain: UUID, runID: UUID, maximumPending: Int = 256) {
        self.clockDomain = clockDomain
        self.runID = runID
        self.maximumPending = max(1, maximumPending)
    }

    public mutating func remember(_ stamp: V2LoadVisibilityStamp, sequence: UInt64,
                                  after appliedCursor: UInt64, at receivedNanoseconds: UInt64,
                                  source: BodySource) -> RememberResult {
        guard stamp.runID == runID else { return .foreignRun }
        guard stamp.clockDomain == clockDomain else { return .foreignClock }
        guard sequence > appliedCursor else { return .alreadyApplied }
        if let previous = pending[sequence] {
            return previous.stamp == stamp ? .duplicate : .conflictingBody
        }
        guard pending.count < maximumPending else { return .capacityExceeded }
        pending[sequence] = Pending(stamp: stamp, receivedNanoseconds: receivedNanoseconds, bodySource: source)
        return .remembered
    }

    public mutating func applied(through cursor: UInt64, at now: UInt64) -> Applied {
        var samples: [Sample] = []
        var invalid = 0
        for sequence in pending.keys.filter({ $0 <= cursor }).sorted() {
            let entry = pending.removeValue(forKey: sequence)!
            let stamp = entry.stamp
            guard entry.receivedNanoseconds >= stamp.scheduledNanoseconds,
                  now >= entry.receivedNanoseconds else { invalid += 1; continue }
            samples.append(.init(cohort: stamp.cohort, sequence: sequence,
                scheduledNanoseconds: stamp.scheduledNanoseconds,
                receivedNanoseconds: entry.receivedNanoseconds, bodySource: entry.bodySource, appliedNanoseconds: now,
                milliseconds: Double(now - stamp.scheduledNanoseconds) / 1_000_000,
                bodyArrivalMilliseconds: Double(entry.receivedNanoseconds - stamp.scheduledNanoseconds) / 1_000_000,
                contiguousApplicationWaitMilliseconds: Double(now - entry.receivedNanoseconds) / 1_000_000))
        }
        return .init(samples: samples, invalidClockSamples: invalid)
    }
}
