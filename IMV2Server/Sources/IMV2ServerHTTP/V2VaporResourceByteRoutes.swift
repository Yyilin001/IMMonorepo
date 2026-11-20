import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import Vapor
import HTTPTypes
import Logging

public struct V2VaporResourceByteRoutes: Sendable {
    let delivery: any V2ResourceByteServing
    private let logger: Logger
    public init(delivery: any V2ResourceByteServing, logger: Logger = Logger(label: "im.v2.resource-bytes")) {
        self.delivery = delivery
        self.logger = logger
    }
    public func register(on routes: RoutesBuilder) {
        routes.get("v2", "resource-bytes", ":placementID") { request async throws -> Response in
            guard let raw = request.parameters.get("placementID"), let id = UUID(uuidString: raw),
                  let cap = request.query[String.self, at: "cap"] else {
                throw Abort(.notFound, headers: [.cacheControl: "private, no-store"])
            }
            do {
                // Authorization and the immutable storage facts are checked before any
                // range response, including 416. Never derive an ETag from modification time.
                let stream = try await delivery.stream(placementID: id, capability: cap)
                var headers = HTTPFields()
                headers[.contentType] = "application/octet-stream"
                headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
                headers[.cacheControl] = "private, no-store"
                headers[.eTag] = stream.etag
                headers[.acceptRanges] = "bytes"
                let range: ResourceResponseRange
                if let validator = request.headers[.ifRange], validator != stream.etag {
                    // Weak validators and dates cannot identify these immutable byte facts.
                    range = .full
                } else {
                    range = resourceResponseRange(request.headers[.range], byteCount: stream.byteCount)
                }
                let start: Int64, end: Int64, status: HTTPResponse.Status
                switch range {
                case .unsatisfiable:
                    await stream.close()
                    headers[.contentRange] = "bytes */\(stream.byteCount)"
                    return .init(status: .rangeNotSatisfiable, headers: headers)
                case .full:
                    start = 0; end = stream.byteCount; status = .ok
                case .selected(let lower, let upper):
                    start = lower; end = upper; status = .partialContent
                    headers[.contentRange] = "bytes \(lower)-\(upper-1)/\(stream.byteCount)"
                }
                do {
                    return try .init(status: status, headers: headers, body: .init(stream: { writer in
                        do {
                            var offset: Int64 = 0
                            while let chunk = try await stream.bytes.next() {
                                try Task.checkCancellation()
                                let nextOffset = offset + Int64(chunk.count)
                                let lower = max(offset, start), upper = min(nextOffset, end)
                                if lower < upper {
                                    let slice = chunk.subdata(in: Int(lower-offset)..<Int(upper-offset))
                                    try await writer.write(slice)
                                }
                                offset = nextOffset
                                // The storage port is sequential: discard the prefix and
                                // drain the suffix through EOF to retain the full SHA check.
                            }
                            await stream.close()
                        } catch {
                            // Awaited reads have ended before releasing their physical slot.
                            await stream.close()
                            if !(error is CancellationError), !Task.isCancelled {
                                logger.warning("Resource byte stream failed",
                                    metadata: V2SafeLogMetadata.failure(error, stage: "resource_stream_bytes"))
                            }
                            throw error
                        }
                    }, count: Int(end-start)))
                } catch {
                    await stream.close()
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch V2ResourceProviderError.notFound {
                throw Abort(.notFound, headers: [.cacheControl: "private, no-store"])
            } catch V2ResourceProviderError.throttled(let retryAfter) {
                let seconds = Int(min(60, max(1, retryAfter.isFinite ? retryAfter : 1)).rounded(.up))
                throw Abort(.tooManyRequests, headers: [.cacheControl: "private, no-store", .retryAfter: String(seconds)])
            } catch {
                logger.warning("Resource byte stream could not be opened",
                    metadata: V2SafeLogMetadata.failure(error, stage: "resource_open_stream"))
                let status: HTTPResponse.Status
                switch error {
                case V2ResourceProviderError.temporarilyUnavailable, V2ResourceProviderError.operationOutcomeUnknown:
                    status = .serviceUnavailable
                case V2ResourceProviderError.integrityMismatch:
                    status = .badGateway
                default:
                    status = .internalServerError
                }
                throw Abort(status, headers: [.cacheControl: "private, no-store"])
            }
        }
    }
}

enum ResourceResponseRange {
    case full
    case selected(Int64, Int64) // Exclusive upper bound.
    case unsatisfiable
}

/// Unsupported units, malformed values and multipart requests are ignored (200).
/// A valid single byte range that selects no bytes receives the authorized 416.
func resourceResponseRange(_ value: String?, byteCount: Int64) -> ResourceResponseRange {
    guard let value, value.utf8.count <= 256, value.hasPrefix("bytes=") else { return .full }
    let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, !spec.contains(",") else { return .full }
    func number(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        // Large, otherwise valid decimal ranges are saturated; no arithmetic overflows.
        return Int64(text) ?? Int64.max
    }
    if parts[0].isEmpty {
        guard let suffix = number(parts[1]) else { return .full }
        guard suffix > 0, byteCount > 0 else { return .unsatisfiable }
        return .selected(max(0, byteCount-suffix), byteCount)
    }
    guard let start = number(parts[0]) else { return .full }
    if parts[1].isEmpty {
        return start < byteCount ? .selected(start, byteCount) : .unsatisfiable
    }
    guard let last = number(parts[1]) else { return .full }
    guard last >= start, start < byteCount else { return .unsatisfiable }
    return .selected(start, min(last, byteCount-1)+1)
}
