import Foundation

/// URLSession task body counters exclude HTTP headers and TLS framing. A retry
/// attempt is not proof that all its bytes duplicate a previously accepted body.
public struct V2ResourceTransferMetric: Sendable {
    public enum Mode: String, Sendable { case upload, multipartUpload, download, rangeDownload }
    public enum Response: String, Sendable { case absent, successStatus, partialResponse, fullResponseForRange, rangeUnsatisfied, other }
    /// Same-entity prefix downloaded again during a verified full-body Range rebuild.
    /// Nil means no proven association, not zero repeated bytes.
    public let verifiedRangeRebuildPrefixBytes: Int64?
    public let mode: Mode
    public let response: Response
    public let bodyBytesSent: Int64
    public let bodyBytesReceived: Int64
    public let elapsed: TimeInterval
    public let retryAttempt: Bool
    public let cancelled: Bool
    public let failed: Bool
    public let statusCode: Int?
    init(mode: Mode, statusCode: Int?, bodyBytesSent: Int64, bodyBytesReceived: Int64,
         elapsed: TimeInterval, retryAttempt: Bool, cancelled: Bool, failed: Bool, verifiedRangeRebuildPrefixBytes: Int64? = nil) {
        self.verifiedRangeRebuildPrefixBytes = verifiedRangeRebuildPrefixBytes.flatMap { $0 >= 0 && $0 <= bodyBytesReceived ? $0 : nil }
        self.mode = mode; self.statusCode = statusCode
        self.bodyBytesSent = bodyBytesSent; self.bodyBytesReceived = bodyBytesReceived
        self.elapsed = elapsed; self.retryAttempt = retryAttempt; self.cancelled = cancelled; self.failed = failed
        switch statusCode {
        case nil: response = .absent
        case 206 where mode == .rangeDownload: response = .partialResponse
        case 200 where mode == .rangeDownload: response = .fullResponseForRange
        case 416: response = .rangeUnsatisfied
        case let code? where (200...299).contains(code): response = .successStatus
        default: response = .other
        }
    }
}

extension V2ResourceTransferMetric {
    func verifyingRangeRebuild(prefixBytes: Int64?) -> Self {
        .init(mode: mode, statusCode: statusCode, bodyBytesSent: bodyBytesSent, bodyBytesReceived: bodyBytesReceived,
              elapsed: elapsed, retryAttempt: retryAttempt, cancelled: cancelled, failed: failed,
              verifiedRangeRebuildPrefixBytes: prefixBytes)
    }
}
