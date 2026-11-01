import Crypto
import Foundation
import Testing
import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("ClamAV scanner process contract", .timeLimit(.minutes(2)))
struct V2ClamAVResourceScannerTests {
    @Test func readinessAndVerifiedObjectVerdicts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scanner = try fixture.scanner()
        try await scanner.verifyReadiness()
        let tiny = try fixture.scanner(maximumBytes: 1)
        try await tiny.verifyReadiness()
        let oversized = try await fixture.store(Data("two bytes".utf8))
        await #expect(throws: V2ResourceProviderError.integrityMismatch) { try await tiny.scan(oversized, storage: fixture.storage) }
        for (body, expected) in [("ordinary bytes", V2MediaScanResult.passed), ("EICAR-STANDARD-ANTIVIRUS-TEST-FILE", .failed)] {
            let facts = try await fixture.store(Data(body.utf8))
            let receipt = try await scanner.scan(facts, storage: fixture.storage)
            #expect(receipt.input == facts && receipt.result == expected)
            #expect(receipt.engineVersion == "clamav-1.4.3")
        }
        // Forged storage metadata must not bypass verification of actual bytes.
        let actual = try await fixture.store(Data("changed bytes".utf8))
        let forged = try V2StoredObjectFacts(reference: actual.reference, byteCount: actual.byteCount, sha256: Data(repeating: 0, count: 32))
        let storage = MisreportedStorage(base: fixture.storage, facts: forged)
        await #expect(throws: V2ResourceProviderError.integrityMismatch) { try await scanner.scan(forged, storage: storage) }
    }

    @Test(arguments: ["engine-error", "silent-success", "false-clean", "wrong-detection", "output-overflow"])
    func readinessFailsClosed(mode: String) async throws {
        let fixture = try Fixture(mode: mode)
        defer { fixture.remove() }
        let scanner = try fixture.scanner()
        await #expect(throws: (any Error).self) { try await scanner.verifyReadiness() }
        if mode != "false-clean", mode != "wrong-detection" {
            let facts = try await fixture.store(Data("ordinary bytes".utf8))
            await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) { try await scanner.scan(facts, storage: fixture.storage) }
        }
    }

    @Test(arguments: [false, true]) func cancellationAndTimeoutDrainChild(timeout: Bool) async throws {
        let fixture = try Fixture(mode: "hang")
        defer { fixture.remove() }
        let scanner = try fixture.scanner(timeout: timeout ? 2 : 120)
        let facts = try await fixture.store(Data("ordinary bytes".utf8))
        let task = Task { try await scanner.scan(facts, storage: fixture.storage) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pid: Int32?
        while pid == nil, ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: fixture.root.appendingPathComponent("pid"), encoding: .utf8)).flatMap(Int32.init)
            await Task.yield()
        }
        guard let pid else {
            task.cancel()
            let result = await task.result
            Issue.record("Scanner did not start: \(String(describing: result))")
            return
        }
        let directory = try String(contentsOf: fixture.root.appendingPathComponent("spool"), encoding: .utf8)
        if timeout { await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) { try await task.value } }
        else { task.cancel(); await #expect(throws: CancellationError.self) { try await task.value } }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let storage: V2LocalResourceStorage
        init(mode: String = "normal") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("clamav-contract-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            executable = root.appendingPathComponent("clamscan")
            storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"), binding: .init(id: "test", configurationRevision: 1))
            func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = """
                #!/bin/sh
                if [ "$1" = '--version' ]; then printf 'ClamAV 1.4.3/12345/test\\n'; exit 0; fi
                # The test process refuses calls that omit the fail-closed policy.
                encrypted=0; exceeded=0; fresh=0; official=0
                for arg in "$@"; do
                  case "$arg" in
                    --alert-encrypted=yes) encrypted=1 ;;
                    --alert-exceeds-max=yes) exceeded=1 ;;
                    --fail-if-cvd-older-than=2) fresh=1 ;;
                    --official-db-only=yes) official=1 ;;
                    --max-filesize=*) maximum=${arg#--max-filesize=} ;;
                    --tempdir=*) printf '%s' "${arg#--tempdir=}" > \(quoted(root.appendingPathComponent("spool").path)) ;;
                  esac
                done
                [ "$encrypted$exceeded$fresh$official" = 1111 ] || exit 2
                case \(quoted(mode)) in
                  engine-error) printf 'ERROR: database unavailable\\n'; exit 2 ;;
                  silent-success) exit 0 ;;
                  false-clean) printf 'stdin: OK\\n'; exit 0 ;;
                  output-overflow) exec /usr/bin/yes x ;;
                  hang) printf '%s' "$$" > \(quoted(root.appendingPathComponent("pid").path)); exec /bin/sleep 30 ;;
                esac
                body=$(/bin/cat)
                if [ "${#body}" -gt "$maximum" ]; then printf 'stdin: Heuristics.Limits.Exceeded FOUND\\n'; exit 1; fi
                case "$body" in
                  *EICAR-STANDARD-ANTIVIRUS-TEST-FILE*)
                    if [ \(quoted(mode)) = 'wrong-detection' ]; then printf 'stdin: Heuristics.Limits.Exceeded FOUND\\n';
                    else printf 'stdin: Win.Test.EICAR FOUND\\n'; fi
                    exit 1 ;;
                  *) printf 'stdin: OK\\n'; exit 0 ;;
                esac
                """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func scanner(maximumBytes: Int64 = 1_048_576, timeout: TimeInterval = 120) throws -> V2ClamAVResourceScanner {
            try .init(executable: executable, databaseDirectory: root, maximumBytes: maximumBytes, timeout: timeout)
        }
        func store(_ bytes: Data) async throws -> V2StoredObjectFacts {
            let file = root.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: file)
            return try await storage.write(storage.allocate(), byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)),
                bytes: V2LocalResourceStorage.stream(file: file))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private struct MisreportedStorage: V2ObjectStorage {
        let base: V2LocalResourceStorage
        let facts: V2StoredObjectFacts
        var binding: V2StorageBinding { base.binding }
        func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts { facts }
        func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream { try await base.read(reference) }
        func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data, bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts {
            throw V2ResourceProviderError.unsupportedCapability
        }
        func delete(_ reference: V2StoredObjectReference) async throws { throw V2ResourceProviderError.unsupportedCapability }
    }
}
