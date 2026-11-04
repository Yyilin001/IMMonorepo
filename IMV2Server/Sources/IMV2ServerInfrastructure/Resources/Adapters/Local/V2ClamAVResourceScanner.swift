import Foundation
import IMV2ServerApplication
import IMV2ServerContracts

/// Runs the configured scan client against verified bytes, with explicit scan
/// limits. Engine errors, skipped scans and unavailable signatures never pass.
/// Worker concurrency and deployment memory/disk limits bound aggregate work.
public struct V2ClamAVResourceScanner: V2ResourceScanner {
    private let executable: URL
    private let databaseDirectory: URL
    private let maximumBytes: Int64
    private let timeout: TimeInterval

    public init(executable: URL, databaseDirectory: URL, maximumBytes: Int64, timeout: TimeInterval = 120) throws {
        guard executable.isFileURL, databaseDirectory.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              maximumBytes > 0, maximumBytes <= 256 * 1_024 * 1_024,
              timeout.isFinite, timeout > 0, timeout <= 120 else { throw V2ResourceProviderError.configurationInvalid }
        self.executable = executable; self.databaseDirectory = databaseDirectory
        self.maximumBytes = maximumBytes; self.timeout = timeout
    }

    /// Exercise the configured engine and signature database before accepting
    /// work. Checking --version alone would miss missing/expired databases.
    public func verifyReadiness() async throws {
        _ = try await engineVersion()
        let samples: [(Data, V2MediaScanResult)] = [
            (Data("IM V2 scanner readiness sample\n".utf8), .passed),
            (Data(#"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#.utf8), .failed)
        ]
        for (bytes, expected) in samples {
            let spool = try await V2ResourceSpoolFile.create(bytes: Self.stream(bytes), byteCount: Int64(bytes.count))
            do {
                // The fixed 68-byte probe must fit even when uploads have a
                // smaller limit, and a size-limit alert is not EICAR detection.
                let result = try await scanFile(spool.url, maximumFileBytes: max(maximumBytes, 68),
                    requiredDetection: expected == .failed ? "eicar" : nil)
                await spool.remove()
                guard result == expected else { throw V2ResourceProviderError.configurationInvalid }
            } catch { await spool.remove(); throw error }
        }
    }

    public func scan(_ input: V2StoredObjectFacts, storage: any V2ObjectStorage) async throws -> V2ResourceScanReceipt {
        try Task.checkCancellation()
        guard input.byteCount <= maximumBytes, try await storage.inspect(input.reference) == input
        else { throw V2ResourceProviderError.integrityMismatch }
        let source = try await storage.read(input.reference)
        let copyDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        let bounded = V2ResourceByteStream {
            let chunk = try await source.next()
            try Task.checkCancellation()
            guard ContinuousClock.now < copyDeadline else { throw V2ResourceProviderError.temporarilyUnavailable }
            return chunk
        }
        let spool = try await V2ResourceSpoolFile.create(bytes: bounded, byteCount: input.byteCount)
        do {
            guard spool.sha256 == input.sha256 else { throw V2ResourceProviderError.integrityMismatch }
            let version = try await engineVersion()
            let result = try await scanFile(spool.url)
            try Task.checkCancellation()
            let receipt = try V2ResourceScanReceipt(input: input, policyVersion: "clamav-bounded-v1-\(maximumBytes)",
                engineVersion: version, result: result)
            await spool.remove()
            return receipt
        } catch { await spool.remove(); throw error }
    }

    private func engineVersion() async throws -> String {
        let output = try await V2ClamAVProcess(executable: executable,
            arguments: ["--version", "--database=\(databaseDirectory.path)"], input: nil, timeout: min(timeout, 10)).run()
        guard output.status == 0, let text = String(data: output.bytes, encoding: .utf8), text.hasPrefix("ClamAV "),
              let version = text.dropFirst(7).split(whereSeparator: { $0 == "/" || $0.isWhitespace }).first,
              version.count <= 64, version.first?.isNumber == true,
              version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0) })
        else { throw V2ResourceProviderError.configurationInvalid }
        return "clamav-\(version)"
    }

    private func scanFile(_ file: URL, maximumFileBytes: Int64? = nil, requiredDetection: String? = nil) async throws -> V2MediaScanResult {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let arguments = ["--stdout", "--no-summary", "--database=\(databaseDirectory.path)",
            "--official-db-only=yes", "--fail-if-cvd-older-than=2", "--bytecode-unsigned=no",
            "--heuristic-alerts=yes", "--alert-encrypted=yes", "--alert-exceeds-max=yes",
            "--max-filesize=\(maximumFileBytes ?? maximumBytes)", "--max-scansize=536870912", "--max-files=10000", "--max-recursion=16",
            "--max-scantime=90000", "--follow-dir-symlinks=0", "--follow-file-symlinks=0",
            "--tempdir=\(file.deletingLastPathComponent().path)", "-"]
        let output = try await V2ClamAVProcess(executable: executable, arguments: arguments, input: input, timeout: timeout).run()
        guard let text = String(data: output.bytes, encoding: .utf8) else { throw V2ResourceProviderError.temporarilyUnavailable }
        let lines = text.split(whereSeparator: \.isNewline)
        // Require a completed scan verdict as well as the exit status. An empty
        // or skipped scan must not be mistaken for a clean object.
        if output.status == 0, lines == ["stdin: OK"] { return .passed }
        if output.status == 1, let detection = lines.first(where: { $0.hasPrefix("stdin: ") && $0.hasSuffix(" FOUND") }),
           !lines.contains(where: { $0.contains("ERROR") }) {
            if let requiredDetection, !detection.lowercased().contains(requiredDetection) {
                throw V2ResourceProviderError.configurationInvalid
            }
            return .failed
        }
        throw V2ResourceProviderError.temporarilyUnavailable
    }

    private static func stream(_ bytes: Data) -> V2ResourceByteStream {
        let reader = ReadinessBytes(bytes)
        return .init { await reader.next() }
    }
}

private actor ReadinessBytes {
    private var bytes: Data?
    init(_ bytes: Data) { self.bytes = bytes }
    func next() -> Data? { defer { bytes = nil }; return bytes }
}
