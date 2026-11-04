import Foundation

public struct DurationMetric: Codable, Sendable {
    public private(set) var count: Int64 = 0
    public private(set) var totalMilliseconds: Double = 0
    public private(set) var maximumMilliseconds: Double = 0
    public private(set) var histogram: [Int64] = Array(repeating: 0, count: 10)
    public static let bucketUpperMilliseconds: [Double] = [0.1, 0.5, 1, 5, 10, 50, 100, 500, 1000, .infinity]
    mutating func record(_ milliseconds: Double) {
        count += 1; totalMilliseconds += milliseconds; maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        histogram[Self.bucketUpperMilliseconds.firstIndex { milliseconds <= $0 } ?? 9] += 1
    }
}

public struct IndexMetrics: Codable, Sendable {
    public internal(set) var accepted: Int64 = 0
    public internal(set) var duplicates: Int64 = 0
    public internal(set) var staleChanges: Int64 = 0
    public internal(set) var unchangedContents: Int64 = 0
    public internal(set) var indexed: Int64 = 0
    public internal(set) var failedBatches: Int64 = 0
    public internal(set) var enqueue = DurationMetric()
    public internal(set) var queueWait = DurationMetric()
    public internal(set) var tokenize = DurationMetric()
    public internal(set) var transaction = DurationMetric()
    public internal(set) var commit = DurationMetric()
    public internal(set) var maintenance = DurationMetric()
}

public struct QueryMetrics: Codable, Sendable {
    public internal(set) var queueWait = DurationMetric()
    public internal(set) var fts = DurationMetric()
    public internal(set) var execution = DurationMetric()
    public internal(set) var materialization = DurationMetric()
    public internal(set) var cancelled: Int64 = 0
    public internal(set) var timedOut: Int64 = 0
}

public struct AdmissionMetrics: Codable, Sendable {
    public let requests: Int
    public let bytes: Int
    public let peakRequests: Int
    public let peakBytes: Int
    public let rejections: Int64
}
public struct SearchDiagnostics: Codable, Sendable {
    public let index: IndexMetrics
    public let query: QueryMetrics
    public let admission: AdmissionMetrics
    public let queryAdmission: AdmissionMetrics
}

func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}
