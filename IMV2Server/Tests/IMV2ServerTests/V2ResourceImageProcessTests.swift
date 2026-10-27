import Foundation
import Testing
@testable import IMV2ServerInfrastructure
import IMV2ServerApplication
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Resource image process lifetime", .serialized, .timeLimit(.minutes(1)))
struct V2ResourceImageProcessTests {
    @Test func immediatelyExitedChildrenAlwaysComplete() async throws {
        let transformer = try V2LocalResourceTransformer(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            temporaryDirectory: FileManager.default.temporaryDirectory)
        // Exercises completion both before and after the async waiter starts.
        // The previous waitUntilExit bridge could strand a Darwin run loop.
        for _ in 0..<64 { try await transformer.verifyReadiness() }
    }

    @Test func nonzeroExitPreservesFailure() async throws {
        let transformer = try V2LocalResourceTransformer(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            temporaryDirectory: FileManager.default.temporaryDirectory)
        await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
            try await transformer.verifyReadiness()
        }
    }

    @Test func cancellationDrainsActualChildBeforeReturning() async throws {
        try await withWorker { transformer, pidFile in
            let operation = Task { try await transformer.verifyReadiness() }
            do {
                let deadline = ContinuousClock.now + .seconds(5)
                while !FileManager.default.fileExists(atPath: pidFile.path) {
                    guard ContinuousClock.now < deadline else {
                        throw WorkerError.didNotStart
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
                operation.cancel()
                await #expect(throws: CancellationError.self) { try await operation.value }
                #expect(kill(pid, 0) == -1 && errno == ESRCH)
            } catch {
                operation.cancel()
                _ = await operation.result
                throw error
            }
        }
    }

    @Test func alreadyCancelledTaskDoesNotLaunchWorker() async throws {
        try await withWorker { transformer, pidFile in
            let operation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await transformer.verifyReadiness()
            }
            await #expect(throws: CancellationError.self) { try await operation.value }
            #expect(!FileManager.default.fileExists(atPath: pidFile.path))
        }
    }

    private enum WorkerError: Error { case didNotStart }

    private func withWorker(_ body: (V2LocalResourceTransformer, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("owned-worker")
        let script = "#!/bin/sh\nprintf '%s' \"$$\" > \"$0.pid\"\nexec /bin/sleep 30\n"
        try Data(script.utf8).write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let transformer = try V2LocalResourceTransformer(executable: executable, temporaryDirectory: directory)
        try await body(transformer, executable.appendingPathExtension("pid"))
    }
}
