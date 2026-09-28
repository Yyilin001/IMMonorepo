import Foundation

/// Body counters originate only from an actual system-task completion receipt.
/// A missing receipt has unknown counts; no payload-size or zero substitution.
/// Cross-process elapsed time and retry classification are intentionally unknown.
public struct V2BackgroundTransferMetric: Sendable {
    public let bodyBytesSent: Int64?
    public let bodyBytesReceived: Int64?
    public let statusCode: Int?
    public let completionObserved: Bool
    public let transportFailed: Bool?
    public let cancelled: Bool?
    /// Same-process cancellation request through actual drain and permit release.
    /// Unknown across restart or when no permit was owned.
    public let cancellationToPermitRelease: TimeInterval?
    init(result: V2BackgroundTransferResult?, cancellationToPermitRelease: TimeInterval? = nil) {
        self.cancellationToPermitRelease = cancellationToPermitRelease.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        bodyBytesSent = result.flatMap { $0.sentBytes >= 0 ? $0.sentBytes : nil }
        bodyBytesReceived = result?.receivedBytes.flatMap { $0 >= 0 ? $0 : nil }
        statusCode = result?.statusCode
        completionObserved = result != nil
        transportFailed = result.map { $0.errorCode != nil }
        cancelled = result.map { $0.errorCode == URLError.cancelled.rawValue }
    }
}
