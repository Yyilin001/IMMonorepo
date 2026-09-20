#if os(macOS)
import Crypto
import Darwin
import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

private final class LocalMediaCrashBundleMarker: NSObject {}

struct V2LocalMediaPurgeCrashTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_MEDIA_CRASH_MODE"] == nil),
          arguments: ["staged", "installed", "purged"])
    func localMediaPurgeKilledRecovery(stage: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-purge-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let host = URL(fileURLWithPath: CommandLine.arguments[0])
        let binary = try #require(Bundle(for: LocalMediaCrashBundleMarker.self).executableURL)
        try #require(host.lastPathComponent == "swiftpm-testing-helper")
        for mode in ["crash", "recover"] {
            let process = Process()
            process.executableURL = host
            process.arguments = ["--test-bundle-path", binary.path, binary.path,
                "--testing-library", "swift-testing", "--filter", "localMediaPurgeCrashChild"]
            var environment = ProcessInfo.processInfo.environment
            environment["IMV2_MEDIA_CRASH_MODE"] = mode
            environment["IMV2_MEDIA_CRASH_ROOT"] = root.path
            environment["IMV2_MEDIA_CRASH_ID"] = id
            environment["IMV2_MEDIA_CRASH_STAGE"] = stage
            process.environment = environment
            let log = root.appending(path: mode + ".log")
            try Data().write(to: log)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = output
            let timeout = Task {
                try await Task.sleep(for: .seconds(30))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            defer { timeout.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
            } onCancel: {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let expected = mode == "crash"
                ? process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
                : process.terminationReason == .exit && process.terminationStatus == 0
            if !expected { Issue.record("\(try String(contentsOf: log, encoding: .utf8))") }
            try #require(expected)
            // A timeout kill cannot masquerade as reaching the intended checkpoint.
            let checkpoint = root.appending(path: mode + ".checkpoint")
            #expect(try String(contentsOf: checkpoint, encoding: .utf8) == stage)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_MEDIA_CRASH_MODE"] != nil))
    func localMediaPurgeCrashChild() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["IMV2_MEDIA_CRASH_ROOT"]))
        try #require(root.lastPathComponent.hasPrefix("im-purge-crash-"))
        let stage = try #require(environment["IMV2_MEDIA_CRASH_STAGE"])
        let mode = try #require(environment["IMV2_MEDIA_CRASH_MODE"])
        let id = try MediaID(#require(environment["IMV2_MEDIA_CRASH_ID"]))
        let now = Date(timeIntervalSince1970: 1_750_000_000), bytes = Data("crash-safe media".utf8)
        let objects = root.appending(path: "objects", directoryHint: .isDirectory)
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: objects,
            targetBaseURL: #require(URL(string: "https://media.test")), signingKey: Data(repeating: 1, count: 32), now: { now })
        try await provider.prepare()
        if mode == "recover" {
            #expect(try FileManager.default.contentsOfDirectory(atPath: objects.appending(path: ".upload-staging").path).isEmpty)
            if stage == "installed" {
                let download = try await provider.issueDownloadTarget(mediaID: id, expiresAt: now.addingTimeInterval(60))
                #expect(try await provider.readDownloadedObject(mediaID: id, targetURL: download.url) == bytes)
            } else {
                await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
                    _ = try await provider.issueDownloadTarget(mediaID: id, expiresAt: now.addingTimeInterval(60))
                }
            }
        }
        let target = try await provider.issueUploadTarget(mediaID: id, contentType: "text/plain",
            byteCount: Int64(bytes.count), expiresAt: now.addingTimeInterval(60))
        let upload = try await provider.beginUploadedObject(mediaID: id, targetURL: target.url,
            contentType: "text/plain", declaredByteCount: Int64(bytes.count))
        try bytes.write(to: upload.fileURL, options: .withoutOverwriting)
        let receipt = try V2ForwardMediaCopyReceipt(byteCount: Int64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
        if mode == "recover" && stage == "purged" {
            await #expect(throws: V2LocalFilesystemMediaProviderError.objectUnavailable) {
                try await provider.commitForwardImportedObject(upload, receipt: receipt)
            }
        } else if mode == "recover" || stage != "staged" {
            try await provider.commitForwardImportedObject(upload, receipt: receipt)
        }
        if mode == "crash" && stage == "purged" { try await provider.purge(mediaID: id) }
        let checkpoint = root.appending(path: mode + ".checkpoint")
        try Data(stage.utf8).write(to: checkpoint)
        if mode == "crash" {
            kill(getpid(), SIGKILL)
            fatalError("SIGKILL must stop the child")
        }
        await provider.discardUploadedObject(upload)
    }
}
#endif
