import Dispatch
import Crypto
import Distributed
import DistributedCluster
import FluentKit
import FluentPostgresDriver
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Logging
import NIOPosix
import NIOSSL
import SQLKit
import Vapor

// Intentionally small wire types: this target checks the real ClusterSystem
// serializer while preserving the application's RoomID representation.
struct ProbeRequest: Codable, Sendable {
    let protocolVersion: Int
    let roomID: RoomID
    let text: String
    let delayMilliseconds: Int
}

struct ProbeReply: Codable, Sendable {
    let roomID: RoomID
    let text: String
    let incarnation: UUID
}

struct ProbeDomainError: Error, Codable, Sendable {
    let code: String
}

struct SignedRequestBody: Codable, Sendable {
    let serviceID: String
    let role: String
    let recipientIncarnation: UUID
    let attemptID: UUID
    let remainingMilliseconds: Int
    let method: String
    let payload: ProbeRequest
}

struct SignedRequest: Codable, Sendable {
    let body: SignedRequestBody
    let signature: Data
}

struct SignedReplyBody: Codable, Sendable {
    let serviceID: String
    let hostIncarnation: UUID
    let attemptID: UUID
    let result: ProbeReply?
    let errorCode: String?
}

struct SignedReply: Codable, Sendable {
    let body: SignedReplyBody
    let signature: Data
}

func canonical(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

distributed actor ProbeRoom {
    typealias ActorSystem = ClusterSystem
    let incarnation: UUID
    let signingKey: Data
    let trustedClientKey: Data

    init(actorSystem: ActorSystem, incarnation: UUID, signingKey: Data, trustedClientKey: Data) {
        self.actorSystem = actorSystem
        self.incarnation = incarnation
        self.signingKey = signingKey
        self.trustedClientKey = trustedClientKey
    }

    distributed func execute(_ request: ProbeRequest) async throws -> ProbeReply {
        guard request.protocolVersion == 1 else { throw ProbeDomainError(code: "protocolMismatch") }
        guard request.text.utf8.count <= 65_536 else { throw ProbeDomainError(code: "payloadTooLarge") }
        guard request.text != "reject" else { throw ProbeDomainError(code: "rejected") }
        if request.delayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(request.delayMilliseconds))
        }
        return ProbeReply(roomID: request.roomID, text: request.text, incarnation: incarnation)
    }

    distributed func signedExecute(_ request: SignedRequest) throws -> SignedReply {
        let body = request.body
        let clientPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: trustedClientKey)
        let validSignature = clientPublicKey.isValidSignature(request.signature, for: try canonical(body))
        let errorCode: String?
        if body.serviceID != "gateway" || body.role != "gateway" {
            errorCode = "untrustedService"
        } else if body.recipientIncarnation != incarnation {
            errorCode = "staleHost"
        } else if body.remainingMilliseconds < 1 || body.remainingMilliseconds > 5_000 {
            errorCode = "invalidBudget"
        } else if body.method != "ProbeRoom.execute.v1" || body.payload.protocolVersion != 1 {
            errorCode = "protocolMismatch"
        } else if body.payload.text.utf8.count > 65_536 {
            errorCode = "payloadTooLarge"
        } else if !validSignature {
            errorCode = "invalidSignature"
        } else {
            errorCode = nil
        }
        let result = errorCode == nil
            ? ProbeReply(roomID: body.payload.roomID, text: body.payload.text, incarnation: incarnation)
            : nil
        let reply = SignedReplyBody(
            serviceID: "room-host", hostIncarnation: incarnation, attemptID: body.attemptID,
            result: result, errorCode: errorCode
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        return SignedReply(body: reply, signature: try privateKey.signature(for: canonical(reply)))
    }
}

enum ProbeFailure: Error {
    case usage
    case databaseUnavailable
    case wrongResult
    case unexpectedError(String)
    case staleReferenceSucceeded
    case markerTimedOut(String)
    case invalidSignedResponse
}

@main
enum VirtualActorCompatibilityProbe {
    static let environment = ProcessInfo.processInfo.environment
    static let directory = URL(fileURLWithPath: environment["VA_EVIDENCE_DIR"] ?? "/evidence")
    static let roomID = RoomID(uuid: UUID(uuidString: "29D69A75-8A25-4B0E-B974-9CE6EC360771")!)

    static func main() async {
        do {
            guard let mode = CommandLine.arguments.dropFirst().first else { throw ProbeFailure.usage }
            switch mode {
            case "host": try await host()
            case "client": try await client()
            case "negative-tls": try await negativeTLS()
            default: throw ProbeFailure.usage
            }
        } catch {
            printLine("PROBE_FAILURE \(error)")
            exit(EXIT_FAILURE)
        }
    }

    static func makeSystem(host: String, port: Int) async throws -> ClusterSystem {
        let certName = environment["VA_CERT_NAME"] ?? "host"
        let caName = environment["VA_CA_FILE"] ?? "ca.pem"
        let cert = try NIOSSLCertificate(
            bytes: [UInt8](Data(contentsOf: directory.appendingPathComponent("\(certName).pem"))), format: .pem
        )
        let key = try NIOSSLPrivateKey(
            bytes: [UInt8](Data(contentsOf: directory.appendingPathComponent("\(certName).key"))), format: .pem
        )
        let ca = try NIOSSLCertificate(
            bytes: [UInt8](Data(contentsOf: directory.appendingPathComponent(caName))), format: .pem
        )
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(cert)], privateKey: .privateKey(key)
        )
        tls.certificateVerification = .fullVerification
        tls.trustRoots = .certificates([ca])
        var settings = ClusterSystemSettings(name: "imv2-va-p0", host: host, port: port, tls: tls)
        // Keep the transport envelope larger than the 64 KiB application
        // request while making the real TLS header-only rejection observable.
        settings.maximumInboundFrameBytes = try .init(bytes: 1_048_576)
        settings.threadPoolSize = 2
        settings.serialization.registerInbound(ProbeDomainError.self)
        settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [ProbeDomainError.self])
        return await ClusterSystem("imv2-va-p0", settings: settings)
    }

    static func host() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "imv2.va.p0.host")
        let bindHost = environment["VA_HOST_NAME"] ?? "imv2-va-p0-host"
        let system = try await makeSystem(host: bindHost, port: 19081)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let databaseResources = V2DatabaseResources(eventLoopGroup: group, logger: logger)
        var app: Application?
        do {
            let databaseURL = environment["VA_DATABASE_URL"] ?? "postgres://probe:probe@postgres:5432/probe"
            let configuration = try SQLPostgresConfiguration(url: databaseURL)
            databaseResources.databases.use(.postgres(configuration: configuration), as: .psql, isDefault: true)
            guard let sql = databaseResources.database(.psql) as? any SQLDatabase,
                  try await sql.raw("SELECT 1").first() != nil else {
                throw ProbeFailure.databaseUnavailable
            }
            printLine("DB_READY")

            let httpPort = Int(environment["VA_HTTP_PORT"] ?? "19080") ?? 19080
            let application = try await V2HTTPService.makeApplication(host: "0.0.0.0", port: httpPort)
            app = application
            application.get("health") { _ async throws -> String in
                guard let sql = databaseResources.database(.psql) as? any SQLDatabase,
                      try await sql.raw("SELECT 1").first() != nil else {
                    throw ProbeFailure.databaseUnavailable
                }
                return "ready"
            }
            let hostIncarnation = UUID()
            let room = ProbeRoom(
                actorSystem: system, incarnation: hostIncarnation,
                signingKey: try Data(contentsOf: directory.appendingPathComponent("host-signing.key")),
                trustedClientKey: try Data(contentsOf: directory.appendingPathComponent("client-signing.pub"))
            )
            try await V2HTTPService.withRunning(application, logger: logger) { _ in
                _ = try await application.server.listeningAddress
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent(environment["VA_ACTOR_ID_FILE"] ?? "actor-old.json")
                try JSONEncoder().encode(room.id).write(to: path, options: .atomic)
                let incarnationPath = directory.appendingPathComponent(
                    environment["VA_HOST_INCARNATION_FILE"] ?? "host-old-incarnation.txt"
                )
                try Data(hostIncarnation.uuidString.utf8).write(to: incarnationPath, options: .atomic)
                printLine("HOST_READY")
                await waitForTerminationSignal()
                printLine("HOST_DRAIN")
            }
            try await application.shutdown()
            app = nil
            printLine("HTTP_STOPPED")
        } catch {
            if let app { try? await app.shutdown() }
            try? await databaseResources.shutdown()
            try? await group.shutdownGracefully()
            try? await system.shutdown().wait()
            throw error
        }
        try await databaseResources.shutdown()
        try await group.shutdownGracefully()
        try await system.shutdown().wait()
        printLine("ALL_STOPPED")
    }

    static func client() async throws {
        let clientHost = environment["VA_CLIENT_NAME"] ?? "imv2-va-p0-client"
        let system = try await makeSystem(host: clientHost, port: 19082)
        do {
            system.cluster.join(host: environment["VA_HOST_NAME"] ?? "imv2-va-p0-host", port: 19081)
            let oldID = try readID("actor-old.json")
            let old = try ProbeRoom.resolve(id: oldID, using: system)
            let reply = try await retryCall(old, request: request(text: "hello"))
            guard reply.roomID == roomID, reply.text == "hello" else { throw ProbeFailure.wrongResult }
            printLine("REMOTE_OK \(reply.incarnation)")

            let hostIncarnation = try readHostIncarnation("host-old-incarnation.txt")
            let signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(contentsOf: directory.appendingPathComponent("client-signing.key"))
            )
            let hostPublicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: Data(contentsOf: directory.appendingPathComponent("host-signing.pub"))
            )
            let signed = try makeSignedRequest(
                text: "authenticated", incarnation: hostIncarnation, signingKey: signingKey
            )
            try await expectSignedResult("authenticated", from: { try await old.signedExecute(signed) },
                                         attemptID: signed.body.attemptID, incarnation: hostIncarnation,
                                         hostKey: hostPublicKey)
            printLine("SIGNED_CALL_OK")
            let tampered = SignedRequest(
                body: SignedRequestBody(
                    serviceID: signed.body.serviceID, role: signed.body.role,
                    recipientIncarnation: signed.body.recipientIncarnation,
                    attemptID: signed.body.attemptID, remainingMilliseconds: signed.body.remainingMilliseconds,
                    method: signed.body.method, payload: request(text: "tampered")
                ), signature: signed.signature
            )
            try await expectSignedError("invalidSignature", from: { try await old.signedExecute(tampered) },
                                        attemptID: tampered.body.attemptID, incarnation: hostIncarnation,
                                        hostKey: hostPublicKey)
            printLine("TAMPER_REJECTED")
            let impostor = try makeSignedRequest(
                text: "impostor", incarnation: hostIncarnation, signingKey: signingKey,
                serviceID: "operator"
            )
            try await expectSignedError("untrustedService", from: { try await old.signedExecute(impostor) },
                                        attemptID: impostor.body.attemptID, incarnation: hostIncarnation,
                                        hostKey: hostPublicKey)
            printLine("WRONG_SERVICE_REJECTED")

            try await expectDomainError("rejected") { try await old.execute(request(text: "reject")) }
            try await expectDomainError("payloadTooLarge") {
                try await old.execute(request(text: String(repeating: "x", count: 65_537)))
            }
            try await expectDomainError("protocolMismatch") {
                try await old.execute(request(text: "hello", version: 2))
            }
            do {
                _ = try await RemoteCall.with(timeout: .milliseconds(150)) {
                    try await old.execute(request(text: "slow", delayMilliseconds: 1_000))
                }
                throw ProbeFailure.unexpectedError("timeout call succeeded")
            } catch let failure as ProbeFailure { throw failure }
              catch { printLine("TIMEOUT_OK \(type(of: error))") }

            try mark("stage1")
            try await waitForMarker("continue1")
            do {
                _ = try await RemoteCall.with(timeout: .seconds(2)) {
                    try await old.execute(request(text: "stale"))
                }
                throw ProbeFailure.staleReferenceSucceeded
            } catch let failure as ProbeFailure { throw failure }
              catch { printLine("STALE_REF_FAILED \(type(of: error))") }

            let newID = try readID("actor-new.json")
            guard try JSONEncoder().encode(oldID) != JSONEncoder().encode(newID) else {
                throw ProbeFailure.wrongResult
            }
            system.cluster.join(host: environment["VA_HOST_NAME"] ?? "imv2-va-p0-host", port: 19081)
            let fresh = try ProbeRoom.resolve(id: newID, using: system)
            let freshReply = try await retryCall(fresh, request: request(text: "fresh"))
            guard freshReply.incarnation != reply.incarnation, freshReply.roomID == roomID else {
                throw ProbeFailure.wrongResult
            }
            printLine("NEW_REF_OK \(freshReply.incarnation)")
        } catch {
            try? await system.shutdown().wait()
            throw error
        }
        try await system.shutdown().wait()
        printLine("CLIENT_STOPPED")
    }

    static func negativeTLS() async throws {
        let system = try await makeSystem(host: "imv2-va-p0-badclient", port: 19083)
        do {
            system.cluster.join(host: "imv2-va-p0-host", port: 19081)
            let old = try ProbeRoom.resolve(id: readID("actor-old.json"), using: system)
            do {
                _ = try await RemoteCall.with(timeout: .seconds(2)) {
                    try await old.execute(request(text: "must-fail"))
                }
                throw ProbeFailure.unexpectedError("untrusted TLS call succeeded")
            } catch let failure as ProbeFailure { throw failure }
              catch { printLine("UNTRUSTED_TLS_REJECTED \(type(of: error))") }
        } catch {
            try? await system.shutdown().wait()
            throw error
        }
        try await system.shutdown().wait()
    }

    static func request(text: String, version: Int = 1, delayMilliseconds: Int = 0) -> ProbeRequest {
        ProbeRequest(protocolVersion: version, roomID: roomID, text: text, delayMilliseconds: delayMilliseconds)
    }

    static func readHostIncarnation(_ file: String) throws -> UUID {
        let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        guard let value = UUID(uuidString: text) else { throw ProbeFailure.wrongResult }
        return value
    }

    static func makeSignedRequest(
        text: String, incarnation: UUID, signingKey: Curve25519.Signing.PrivateKey,
        serviceID: String = "gateway"
    ) throws -> SignedRequest {
        let body = SignedRequestBody(
            serviceID: serviceID, role: "gateway", recipientIncarnation: incarnation,
            attemptID: UUID(), remainingMilliseconds: 2_000,
            method: "ProbeRoom.execute.v1", payload: request(text: text)
        )
        return SignedRequest(body: body, signature: try signingKey.signature(for: canonical(body)))
    }

    static func verifySignedReply(
        _ reply: SignedReply, attemptID: UUID, incarnation: UUID,
        hostKey: Curve25519.Signing.PublicKey
    ) throws {
        guard reply.body.serviceID == "room-host", reply.body.attemptID == attemptID,
              reply.body.hostIncarnation == incarnation,
              hostKey.isValidSignature(reply.signature, for: try canonical(reply.body)) else {
            throw ProbeFailure.invalidSignedResponse
        }
    }

    static func expectSignedResult(
        _ text: String, from operation: () async throws -> SignedReply,
        attemptID: UUID, incarnation: UUID, hostKey: Curve25519.Signing.PublicKey
    ) async throws {
        let reply = try await operation()
        try verifySignedReply(reply, attemptID: attemptID, incarnation: incarnation, hostKey: hostKey)
        guard reply.body.result?.text == text, reply.body.errorCode == nil else {
            throw ProbeFailure.invalidSignedResponse
        }
    }

    static func expectSignedError(
        _ code: String, from operation: () async throws -> SignedReply,
        attemptID: UUID, incarnation: UUID, hostKey: Curve25519.Signing.PublicKey
    ) async throws {
        let reply = try await operation()
        try verifySignedReply(reply, attemptID: attemptID, incarnation: incarnation, hostKey: hostKey)
        guard reply.body.errorCode == code, reply.body.result == nil else {
            throw ProbeFailure.invalidSignedResponse
        }
    }

    static func readID(_ name: String) throws -> ClusterSystem.ActorID {
        try JSONDecoder().decode(ClusterSystem.ActorID.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
    }

    static func retryCall(_ room: ProbeRoom, request: ProbeRequest) async throws -> ProbeReply {
        var latest: (any Error)?
        for _ in 0..<20 {
            do {
                return try await RemoteCall.with(timeout: .seconds(2)) { try await room.execute(request) }
            } catch {
                latest = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw latest ?? ProbeFailure.wrongResult
    }

    static func expectDomainError(_ code: String, operation: () async throws -> ProbeReply) async throws {
        do {
            _ = try await operation()
            throw ProbeFailure.unexpectedError("\(code) call succeeded")
        } catch let domain as ProbeDomainError {
            guard domain.code == code else { throw ProbeFailure.unexpectedError(domain.code) }
            printLine("DOMAIN_ERROR_OK \(code)")
        }
    }

    static func mark(_ name: String) throws {
        try Data().write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func waitForMarker(_ name: String) async throws {
        let path = directory.appendingPathComponent(name).path
        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ProbeFailure.markerTimedOut(name)
    }

    static func waitForTerminationSignal() async {
        signal(SIGTERM, SIG_IGN)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { continuation.yield(()) }
        source.resume()
        for await _ in stream { break }
        source.cancel()
        continuation.finish()
    }

    static func printLine(_ line: String) {
        let bytes = [UInt8]((line + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
    }
}
