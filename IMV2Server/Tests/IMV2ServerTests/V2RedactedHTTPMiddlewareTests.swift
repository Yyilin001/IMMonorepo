import Foundation
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 redacted HTTP middleware")
struct V2RedactedHTTPMiddlewareTests {
    @Test("logs only route templates and never query capabilities, path identifiers, or error descriptions")
    func redactsCallerAndErrorData() async throws {
        let capture = CapturedHTTPLogs()
        let logger = Logger(label: "im-v2-redacted-test") { _ in
            CapturingHTTPLogHandler(capture: capture)
        }
        let app = try await Application.make(.testing, logger: logger)
        do {
            V2RedactedHTTPMiddlewareConfiguration.install(on: app)
            app.get("objects", ":mediaID") { _ async throws -> Response in
                throw Abort(.forbidden)
            }
            app.get("internal") { _ async throws -> Response in
                throw SensitiveTestFailure()
            }
            let tester = try app.testing()
            try await tester.test(
                .GET,
                "/objects/private-media-id?target=secret-signed-capability"
            ) { response async in
                #expect(response.status == .forbidden)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
            try await tester.test(.GET, "/internal") { response async throws in
                #expect(response.status == .internalServerError)
                let body = String(decoding: response.body.readableBytesView, as: UTF8.self)
                #expect(body.contains("Something went wrong."))
                #expect(!body.contains(SensitiveTestFailure.secret))
            }

            let rendered = capture.rendered()
            #expect(rendered.contains("GET /objects/:mediaID"))
            #expect(!rendered.contains("secret-signed-capability"))
            #expect(!rendered.contains("private-media-id"))
            #expect(!rendered.contains(SensitiveTestFailure.secret))
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private struct SensitiveTestFailure: Error, CustomStringConvertible {
    static let secret = "postgres://operator:password@private-host/database"
    var description: String { Self.secret }
}

private final class CapturedHTTPLogs: @unchecked Sendable {
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

private struct CapturingHTTPLogHandler: LogHandler {
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
