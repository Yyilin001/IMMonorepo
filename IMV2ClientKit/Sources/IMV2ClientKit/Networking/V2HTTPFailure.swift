import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport observations do not prove whether a business mutation committed.
public struct V2HTTPFailure: Error, Equatable, Sendable {
    public enum Kind: String, Sendable { case invalidEndpoint, invalidResponse, responseTooLarge, deadlineExceeded, transport, httpStatus }
    public enum Certainty: String, Sendable { case notStarted, outcomeUnknown, responseReceived }
    public let kind: Kind
    public let service: String
    public let statusCode: Int?
    public let urlErrorCode: Int?
    public let retryAfter: Date?
    public let certainty: Certainty
    public init(kind: Kind, service: String, statusCode: Int? = nil, urlErrorCode: Int? = nil, retryAfter: Date? = nil, certainty: Certainty = .outcomeUnknown) {
        self.kind = kind; self.service = service; self.statusCode = statusCode
        self.urlErrorCode = urlErrorCode; self.retryAfter = retryAfter; self.certainty = certainty
    }
    public static func status(_ response: HTTPURLResponse, service: String, now: Date = Date()) -> Self {
        .init(kind: .httpStatus, service: service, statusCode: response.statusCode,
              retryAfter: V2RetryAfter.date(from: response.value(forHTTPHeaderField: "Retry-After"), now: now), certainty: .responseReceived)
    }
}
