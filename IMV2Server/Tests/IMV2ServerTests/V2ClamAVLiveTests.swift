import Crypto
import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import Testing
@testable import IMV2ServerInfrastructure

/// Uses an explicitly supplied engine and database. Does not download signatures,
/// update the supplied database or start a scanner service.
@Suite("ClamAV real engine contract", .serialized, .timeLimit(.minutes(5)))
struct V2ClamAVLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IM_V2_CLAMAV_LIVE_TEST"] == "1"))
    func configuredEngineScansVerifiedResources() async throws {
        let executable = try configuredURL("IM_V2_RESOURCE_CLAMSCAN_EXECUTABLE")
        let database = try configuredURL("IM_V2_RESOURCE_CLAMAV_DATABASE_DIRECTORY")
        let scanner = try V2ClamAVResourceScanner(executable: executable, databaseDirectory: database,
            maximumBytes: 1_048_576)
        try await scanner.verifyReadiness()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clamav-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"),
            binding: .init(id: "clamav-live", configurationRevision: 1))
        let samples: [(Data, V2MediaScanResult)] = [
            (Data("IM V2 real engine clean sample\n".utf8), .passed),
            (Data(#"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#.utf8), .failed)
        ]
        for (bytes, expected) in samples {
            let source = root.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: source)
            let facts = try await storage.write(storage.allocate(), byteCount: Int64(bytes.count),
                sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: source))
            let receipt = try await scanner.scan(facts, storage: storage)
            #expect(receipt.input == facts)
            #expect(receipt.result == expected)
            #expect(receipt.engineVersion.hasPrefix("clamav-"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IM_V2_CLAMAV_LIVE_TEST"] == "1"))
    func configuredEngineRejectsMissingSignatures() async throws {
        let executable = try configuredURL("IM_V2_RESOURCE_CLAMSCAN_EXECUTABLE")
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("clamav-empty-db-\(UUID())")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: database) }

        // A missing library or unusable executable must fail this test instead
        // of being mistaken for proof that signature validation failed closed.
        let version = try await V2ClamAVProcess(executable: executable,
            arguments: ["--version", "--database=\(database.path)"], input: nil, timeout: 10).run()
        try #require(version.status == 0)
        try #require(String(data: version.bytes, encoding: .utf8)?.hasPrefix("ClamAV ") == true)
        let scanner = try V2ClamAVResourceScanner(executable: executable, databaseDirectory: database,
            maximumBytes: 1_048_576)
        await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
            try await scanner.verifyReadiness()
        }
    }

    @Test func explicitlyDisabledScannerChecksIntegrityWithoutAntivirus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"),
            binding: .init(id: "integrity-test", configurationRevision: 1))
        let bytes = Data(#"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#.utf8)
        let source = root.appendingPathComponent("sample")
        try bytes.write(to: source)
        let facts = try await storage.write(storage.allocate(), byteCount: Int64(bytes.count),
            sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: source))
        let scanner = V2IntegrityOnlyResourceScanner(maximumBytes: Int64(bytes.count))
        let receipt = try await scanner.scan(facts, storage: storage)
        #expect(receipt.result == .passed)
        #expect(receipt.engineVersion == "antivirus-disabled")
        let altered = try V2StoredObjectFacts(reference: facts.reference, byteCount: facts.byteCount, sha256: Data(repeating: 0, count: 32))
        await #expect(throws: V2ResourceProviderError.integrityMismatch) {
            _ = try await scanner.scan(altered, storage: storage)
        }
    }

    private func configuredURL(_ key: String) throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment[key])
        try #require(path.hasPrefix("/"), "\(key) must be an absolute path")
        return URL(fileURLWithPath: path)
    }
}
