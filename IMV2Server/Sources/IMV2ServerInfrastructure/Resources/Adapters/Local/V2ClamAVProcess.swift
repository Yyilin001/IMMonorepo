import Foundation
import Synchronization
import IMV2ServerApplication
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A single trusted executable, fixed resource ceilings and bounded output.
/// Cancellation/deadline waits for physical process exit before releasing input.
final class V2ClamAVProcess: @unchecked Sendable {
    struct Output: Sendable { let status: Int32; let bytes: Data }
    private struct State { var stopped = false; var finished = false }
    private let state = Mutex(State())
    private let process = Process()
    private let pipe = Pipe()
    private let termination: AsyncStream<Void>
    private let timeout: TimeInterval

    init(executable: URL, arguments: [String], input: FileHandle?, timeout: TimeInterval) {
        self.timeout = timeout
        let exit = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        termination = exit.stream
        process.terminationHandler = { _ in exit.continuation.yield(()); exit.continuation.finish() }
        #if os(Linux)
        let memory = "ulimit -v 2097152 || exit 78; "
        #else
        let memory = ""
        #endif
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ulimit -t 120 || exit 78; ulimit -n 64 || exit 78; ulimit -f 1048576 || exit 78; " + memory + "exec \"$@\"",
            "im-v2-clamav", executable.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "OMP_NUM_THREADS": "1"]
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
    }

    private func stop() {
        state.withLock { value in
            value.stopped = true
            if !value.finished, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }

    func run() async throws -> Output {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try state.withLock { value in
                guard !value.stopped else { throw CancellationError() }
                try process.run()
            }
            let deadline = Task { [self] in
                do { try await Task.sleep(for: .seconds(timeout)); stop() } catch { }
            }
            let bytes = await Task.detached(priority: .utility) { [self] in
                var bytes = Data()
                do {
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                        guard bytes.count + chunk.count <= 65_536 else { stop(); break }
                        bytes.append(chunk)
                    }
                } catch { stop() }
                return bytes
            }.value
            await Task.detached { [termination] in
                for await _ in termination { break }
            }.value
            state.withLock { $0.finished = true }
            deadline.cancel(); _ = await deadline.result
            try Task.checkCancellation()
            guard !state.withLock({ $0.stopped }), process.terminationReason == .exit
            else { throw V2ResourceProviderError.temporarilyUnavailable }
            return Output(status: process.terminationStatus, bytes: bytes)
        } onCancel: { [self] in stop() }
    }
}
