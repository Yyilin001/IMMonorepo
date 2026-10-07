import Foundation
@preconcurrency import NIOSSL
import Testing

func makeGatewayTestTLSContexts() throws -> (server: NIOSSLContext, client: NIOSSLContext) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "imv2-gateway-tls-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cert = directory.appending(path: "cert.pem"), key = directory.appending(path: "key.pem")
    let openssl = Process()
    openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    openssl.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-keyout", key.path, "-out", cert.path]
    openssl.standardOutput = FileHandle.nullDevice; openssl.standardError = FileHandle.nullDevice
    try openssl.run(); openssl.waitUntilExit()
    try #require(openssl.terminationStatus == 0)
    let certificates = try NIOSSLCertificate.fromPEMFile(cert.path)
    var server = TLSConfiguration.makeServerConfiguration(certificateChain: certificates.map { .certificate($0) },
        privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem)))
    server.minimumTLSVersion = .tlsv13
    var client = TLSConfiguration.makeClientConfiguration()
    client.minimumTLSVersion = .tlsv13; client.trustRoots = .certificates(certificates)
    return (try NIOSSLContext(configuration: server), try NIOSSLContext(configuration: client))
}
