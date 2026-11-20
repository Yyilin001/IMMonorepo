import HTTPTypes
import Foundation
import IMV2ServerHTTP
import IMV2ServerApplication
import Logging
import Testing
import Vapor
import VaporTesting

@Suite("V2 redacted HTTP middleware")
struct V2RedactedHTTPMiddlewareTests {
    @Test func resourceByteFailuresKeepHTTPStatusAndSafeDiagnostics() async throws {
        let cases: [(V2ResourceProviderError, HTTPResponse.Status, String?)] = [
            (.notFound, .notFound, nil),
            (.throttled(retryAfter: 2.5), .tooManyRequests, nil),
            (.temporarilyUnavailable, .serviceUnavailable, "resource_temporarily_unavailable"),
            (.integrityMismatch, .badGateway, "resource_integrity_mismatch"),
            (.configurationInvalid, .internalServerError, "resource_configuration_invalid")
        ]
        for (failure, status, errorCode) in cases {
            let capture = CapturedHTTPLogs()
            let logger = Logger(label: "resource-byte-failure") { _ in CapturingHTTPLogHandler(capture: capture) }
            try await withApp(logger: logger) { app in
                V2RedactedHTTPMiddlewareConfiguration.install(on: app)
                V2VaporResourceByteRoutes(delivery: FailingByteServing(error: failure), logger: logger).register(on: app)
                try await app.testing { client in
                    let response = try await client.send(.get, to: "/v2/resource-bytes/\(UUID())?cap=secret-cap")
                    #expect(response.status == status)
                    #expect(response.headers[.cacheControl] == "no-store")
                    if status == .tooManyRequests { #expect(response.headers[.retryAfter] == "3") }
                }
            }
            if let errorCode { #expect(capture.rendered().contains(errorCode)) }
            #expect(!capture.rendered().contains("secret-cap"))
        }
    }

    @Test("logs only route templates and never query capabilities, path identifiers, or error descriptions")
    func redactsCallerAndErrorData() async throws {
        let capture = CapturedHTTPLogs()
        let logger = Logger(label: "im-v2-redacted-test") { _ in
            CapturingHTTPLogHandler(capture: capture)
        }
        try await withApp(logger: logger) { app in
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            app.get("objects", ":mediaID") { _ async throws -> Response in
                throw Abort(.forbidden)
            }
            app.get("internal") { _ async throws -> Response in
                throw SensitiveTestFailure()
            }
            app.get("abort-reason") { _ async throws -> Response in
                throw Abort(.badRequest, reason: SensitiveTestFailure.secret)
            }

            try await app.testing { client in
                let response = try await client.send(.get, headers: [.authorization: "Bearer secret-access-token"], to: "/objects/private-media-id?target=secret-signed-capability")
                #expect(response.status == .forbidden)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await app.testing { client in
                let response = try await client.send(.get, to: "/internal")
                #expect(response.status == .internalServerError)
                let body = try await response.body.string() ?? ""
                #expect(body.contains("Something went wrong."))
                #expect(!body.contains(SensitiveTestFailure.secret))
            }
            try await app.testing { client in
                let response = try await client.send(.get, to: "/abort-reason")
                #expect(response.status == .badRequest)
                let body = try await response.body.string() ?? ""
                #expect(body.contains("Bad Request"))
                #expect(!body.contains(SensitiveTestFailure.secret))
            }

            let rendered = capture.rendered()
            #expect(rendered.contains("GET /objects/:mediaID"))
            #expect(!rendered.contains("secret-signed-capability"))
            #expect(!rendered.contains("private-media-id"))
            #expect(!rendered.contains("secret-access-token"))
            #expect(!rendered.contains(SensitiveTestFailure.secret))
        }
    }
}

private struct SensitiveTestFailure: Error, CustomStringConvertible {
    static let secret = "postgres://operator:password@private-host/database"
    var description: String { Self.secret }
}

final class CapturedHTTPLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []

    func append(message: Logger.Message, metadata: Logger.Metadata) {
        lock.lock()
        records.append("\(message) \(metadata)")
        lock.unlock()
    }

    func rendered() -> String {
        lock.lock()
        defer { lock.unlock() }
        return records.joined(separator: "\n")
    }
}

struct CapturingHTTPLogHandler: LogHandler {
    let capture: CapturedHTTPLogs
    var metadataProvider: Logger.MetadataProvider?
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    init(capture: CapturedHTTPLogs) {
        self.capture = capture
        metadataProvider = nil
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let combined = metadata.merging(event.metadata ?? [:]) { _, explicit in explicit }
        capture.append(message: event.message, metadata: combined)
    }
}

private struct FailingByteServing: V2ResourceByteServing {
    let error: V2ResourceProviderError
    func stream(placementID: UUID, capability: String) async throws
        -> (byteCount: Int64, etag: String, bytes: V2ResourceByteStream, close: @Sendable () async -> Void) {
        throw error
    }
}
