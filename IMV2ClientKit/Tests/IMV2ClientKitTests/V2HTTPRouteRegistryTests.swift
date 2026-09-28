import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import IMV2ClientKit
import Testing

@Suite("Production network entry registration", .serialized)
struct V2HTTPRouteRegistryTests {
    @Test func everyDeclaredServerRouteHasAnExecutablePolicy() throws {
        let root = try repositoryRoot()
        let files = try FileManager.default.contentsOfDirectory(at: root.appending(path: "IMV2Server/Sources/IMV2ServerHTTP"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        var seen = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for route in try SwiftRouteCalls.read(source) {
                let policy = try #require(V2HTTPRouteRegistry.policy(method: route.method, path: route.path), "Missing route policy: \(file.lastPathComponent) \(route.method) \(route.path)")
                #expect(!policy.permitsAutomaticReplay)
                #expect(policy.requiresAccountScope == policy.kind.accountTransportAllowed)
                seen.insert(route.method + " " + policy.path)
            }
        }
        #expect(seen.contains("POST /v2/device-credentials"))
        #expect(seen.contains("POST /v2/resource-uploads/targets"))
        #expect(seen.contains("POST /v2/rooms/*/message-operations/send"))
        #expect(Set(V2HTTPRouteRegistry.policies.map { $0.method + " " + $0.path }).count == V2HTTPRouteRegistry.policies.count)
    }

    @Test func newlyAddedRequestBuildersAndWireAdaptersRequireBoundaryRegistration() throws {
        let root = try repositoryRoot().appending(path: "IMV2ClientKit/Sources/IMV2ClientKit")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var discovered = Set<String>()
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if ["URLRequest(", "URLSession(", "transport.data(for:", "executor.execute(", ".dataTask(", ".uploadTask(", ".downloadTask("].contains(where: source.contains) {
                discovered.insert(file.lastPathComponent)
            }
            #expect(!source.contains("session.data(for:") && !source.contains("URLSession.shared"), "Unbounded HTTP bypass: \(file.lastPathComponent)")
        }
        #expect(discovered == Set(V2NetworkEntryRegistry.sources.keys))
        for kind in V2OperationKind.allCases { #expect(!V2NetworkEntryRegistry.boundaries(for: kind).isEmpty) }
        let app = try String(contentsOf: try repositoryRoot().appending(path: "IMApp/IMApp/V2/V2AppStore.swift"), encoding: .utf8)
        let runtime = try String(contentsOf: try repositoryRoot().appending(path: "IMApp/IMApp/V2/V2AppRealtimeRuntime.swift"), encoding: .utf8)
        for source in [app, runtime] {
            #expect(source.contains("V2RegisteredAccountHTTPTransport(executor:"))
            #expect(source.contains("authorizationDomain: \"accountHTTP\""))
            #expect(!source.contains("V2URLSessionAuthHTTPTransport(executor:"))
        }
    }

    @Test func missingScopeUnknownRoutesAndWrongCapabilitiesFailBeforeIO() async throws {
        let executor = V2HTTPExecutor()
        let base = URL(string: "https://account.example/prefix")!
        let scope = V2QueryScope(accountID: "account", authorizationDomain: "accountHTTP", activationID: UUID(), generation: 2)
        #expect(throws: V2RegisteredAccountHTTPTransport.RegistrationError.invalidScope) {
            try V2RegisteredAccountHTTPTransport(executor: executor, allowedBases: [base], scope: .init(accountID: "", authorizationDomain: "accountHTTP", activationID: UUID()))
        }
        let leaf = try V2RegisteredAccountHTTPTransport(executor: executor, allowedBases: [base], scope: scope)
        for (method, path) in [("POST", "/v2/device-credentials/refresh"), ("PUT", "/v2/local-media/upload/object"), ("POST", "/internal/v2/accounts/disable")] {
            var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
            request.httpMethod = method
            await #expect(throws: V2HTTPFailure(kind: .invalidEndpoint, service: "accountPolicy", certainty: .notStarted)) { _ = try await leaf.data(for: request) }
        }
        await #expect(throws: V2HTTPFailure(kind: .invalidEndpoint, service: "accountPolicy", certainty: .notStarted)) {
            _ = try await leaf.data(for: URLRequest(url: base.appendingPathComponent("v2/new-unclassified-read")))
        }
        for url in ["https://other.example/prefix/v2/profile/me", "https://account.example/prefix-evil/v2/profile/me", "https://account.example/prefix/v2/rooms/a%2Fb/avatar"] {
            await #expect(throws: V2HTTPFailure(kind: .invalidEndpoint, service: "accountPolicy", certainty: .notStarted)) { _ = try await leaf.data(for: URLRequest(url: URL(string: url)!)) }
        }
    }

    @Test func productionLeafRunsThroughBoundedExecutorWithOneAccountPermit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegisteredRouteProtocol.self]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let scheduler = V2AccountWorkScheduler(configuration: .init(ordinaryLimit: 1, serviceLimit: 1))
        let leaf = try V2RegisteredAccountHTTPTransport(executor: .init(session: session, scheduler: scheduler),
            allowedBases: [URL(string: "https://account.example")!, URL(string: "https://account.example/prefix")!],
            scope: .init(accountID: "account-a", authorizationDomain: "accountHTTP", activationID: UUID()))
        let result = try await leaf.data(for: URLRequest(url: URL(string: "https://account.example/prefix/v2/profile/me")!))
        #expect(result.0 == Data("{}".utf8))
        #expect(await scheduler.snapshot().active == 0)
        #expect(await scheduler.snapshot().waiting == 0)
        await scheduler.closeAndDrain()
    }

    private func repositoryRoot() throws -> URL {
        for start in [URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent(), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            var path = start
            for _ in 0..<12 {
                if FileManager.default.fileExists(atPath: path.appending(path: "IMV2Server/Sources/IMV2ServerHTTP").path) { return path }
                path.deleteLastPathComponent()
            }
        }
        throw RegistrySourceError.repositoryMissing
    }
}
private enum RegistrySourceError: Error { case repositoryMissing, malformedRoute }

/// Reads balanced registration calls rather than counting textual occurrences.
/// Dynamic route components must have an explicit, verifiable expansion.
private enum SwiftRouteCalls {
    struct Route { let method: String; let path: String }
    static func read(_ source: String) throws -> [Route] {
        let expression = try NSRegularExpression(pattern: #"routes\.(get|post|put|delete|patch|on)\s*\("#)
        let ns = source as NSString
        var result: [Route] = []
        for match in expression.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let methodToken = ns.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            var cursor = start, depth = 1, quoted = false, escaped = false
            while cursor < ns.length && depth > 0 {
                let value = ns.character(at: cursor)
                if quoted {
                    if escaped { escaped = false }
                    else if value == 92 { escaped = true }
                    else if value == 34 { quoted = false }
                } else if value == 34 { quoted = true }
                else if value == 40 { depth += 1 }
                else if value == 41 { depth -= 1 }
                cursor += 1
            }
            guard depth == 0 else { throw RegistrySourceError.malformedRoute }
            var arguments = ns.substring(with: NSRange(location: start, length: cursor - start - 1))
            let method: String
            if methodToken == "on" {
                let first = arguments.split(separator: ",", maxSplits: 1)
                guard first.count == 2 else { throw RegistrySourceError.malformedRoute }
                method = first[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "").uppercased()
                arguments = String(first[1])
            } else { method = methodToken.uppercased() }
            arguments = arguments.components(separatedBy: "maxBodySize:")[0]
            let strings = try NSRegularExpression(pattern: #"\"([^\"]*)\""#)
            let values = strings.matches(in: arguments, range: NSRange(location: 0, length: (arguments as NSString).length)).map { (arguments as NSString).substring(with: $0.range(at: 1)) }
            guard !values.isEmpty else { throw RegistrySourceError.malformedRoute }
            let paths: [[String]]
            if arguments.contains("PathComponent(stringLiteral: action)") {
                guard source.contains(#"for action in ["change", "recovery-code", "recover"]"#) else { throw RegistrySourceError.malformedRoute }
                paths = ["change", "recovery-code", "recover"].map { values + [$0] }
            } else { paths = [values] }
            result += paths.map { .init(method: method, path: "/" + $0.map { $0.hasPrefix(":") ? "entity" : $0 }.joined(separator: "/")) }
        }
        return result
    }
}

private final class RegisteredRouteProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
