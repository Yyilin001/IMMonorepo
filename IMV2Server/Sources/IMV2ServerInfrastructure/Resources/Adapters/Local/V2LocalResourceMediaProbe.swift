import Foundation
import Crypto
import Synchronization
import IMV2ServerApplication
import IMV2ServerContracts
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The probe receives a verified seekable FD, not a URL, storage key or credential.
/// A fixed shell applies resource ceilings then execs ffprobe in the SAME PID.
/// Cancellation/deadline kills that process and drains stdout + the exit callback.
public struct V2LocalResourceMediaProbe: V2ResourceMediaProbing {
    public static var defaultExecutable: URL {
        #if os(Linux)
        URL(fileURLWithPath: "/usr/bin/ffprobe")
        #else
        URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffprobe") ? "/opt/homebrew/bin/ffprobe" : "/usr/local/bin/ffprobe")
        #endif
    }
    private let executable: URL
    private let temporaryDirectory: URL
    private let maximumBytes: Int64
    private let timeout: TimeInterval
    public init(executable: URL = Self.defaultExecutable, temporaryDirectory: URL, maximumBytes: Int64, timeout: TimeInterval = 20) throws {
        guard executable.isFileURL, temporaryDirectory.isFileURL, maximumBytes > 0, timeout.isFinite, timeout > 0, timeout <= 20,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw V2ResourceProviderError.configurationInvalid }
        self.executable = executable; self.temporaryDirectory = temporaryDirectory; self.maximumBytes = maximumBytes; self.timeout = timeout
    }
    public func verifyReadiness() async throws {
        _ = try await V2BoundedMediaProbeProcess(executable: executable, arguments: ["-version"], input: nil, timeout: timeout).run()
    }
    public func probe(_ input: V2StoredObjectFacts, contentType: String, storage: any V2ObjectStorage) async throws -> V2ResourceTimedMediaMetadata {
        try Task.checkCancellation()
        guard input.byteCount <= maximumBytes else { throw V2ResourceTransformError.contentRejected }
        let (kind, format) = try Self.format(contentType)
        let directory = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("input")
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data().write(to: file, options: .withoutOverwriting)
            }.value
            try Task.checkCancellation()
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let stream = try await storage.read(input.reference)
            let copyDeadline = ContinuousClock.now.advanced(by: .seconds(120))
            var digest = SHA256(), count: Int64 = 0
            while let chunk = try await stream.next() {
                try Task.checkCancellation()
                guard ContinuousClock.now < copyDeadline else { throw V2ResourceProviderError.temporarilyUnavailable }
                guard Int64(chunk.count) <= input.byteCount - count else { throw V2ResourceProviderError.integrityMismatch }
                count += Int64(chunk.count); digest.update(data: chunk)
                try await Task.detached(priority: .utility) { try handle.write(contentsOf: chunk) }.value
            }
            try handle.close()
            guard count == input.byteCount, Data(digest.finalize()) == input.sha256 else { throw V2ResourceProviderError.integrityMismatch }
            try Task.checkCancellation()
            let fd = try FileHandle(forReadingFrom: file)
            defer { try? fd.close() }
            var arguments = ["-hide_banner", "-v", "error", "-max_alloc", "16777216", "-probesize", "2097152", "-analyzeduration", "2000000",
                "-protocol_whitelist", "file", "-format_whitelist", format, "-f", format]
            // MOV aliases/data references must not open a different local object.
            if format == "mov" { arguments += ["-enable_drefs", "0", "-use_absolute_path", "0"] }
            arguments += ["-show_entries", "stream=codec_type,width,height:stream_disposition=attached_pic:format=duration", "-of", "json", "-i", "/dev/fd/0"]
            let bytes = try await V2BoundedMediaProbeProcess(executable: executable, arguments: arguments, input: fd, timeout: timeout).run()
            let result = try Self.decode(bytes, kind: kind)
            await remove(directory); return result
        } catch { await remove(directory); throw error }
    }
    private func remove(_ directory: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }
    static func format(_ contentType: String) throws -> (V2ResourceTimedMediaKind, String) {
        switch contentType {
        case "video/mp4", "video/quicktime", "video/x-m4v", "video/3gpp": (.video, "mov")
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/3gpp": (.audio, "mov")
        case "video/webm", "video/x-matroska": (.video, "matroska")
        case "audio/webm", "audio/x-matroska": (.audio, "matroska")
        case "audio/mpeg", "audio/mp3": (.audio, "mp3")
        case "audio/wav", "audio/x-wav", "audio/vnd.wave": (.audio, "wav")
        case "audio/ogg", "audio/opus": (.audio, "ogg")
        case "video/ogg": (.video, "ogg")
        case "audio/flac", "audio/x-flac": (.audio, "flac")
        case "audio/aac", "audio/x-aac": (.audio, "aac")
        case "audio/amr": (.audio, "amr")
        case "audio/aiff", "audio/x-aiff": (.audio, "aiff")
        case "video/x-msvideo": (.video, "avi")
        case "video/mpeg": (.video, "mpeg")
        case "video/mp2t": (.video, "mpegts")
        default: throw V2ResourceTransformError.contentRejected
        }
    }
    static func decode(_ data: Data, kind: V2ResourceTimedMediaKind) throws -> V2ResourceTimedMediaMetadata {
        struct Stream: Decodable {
            let codec_type: String; let width: Int?; let height: Int?; let disposition: Disposition?
            struct Disposition: Decodable { let attached_pic: Int? }
        }
        struct Probe: Decodable {
            let streams: [Stream]; let format: Format
            struct Format: Decodable { let duration: String? }
        }
        do {
            let result = try JSONDecoder().decode(Probe.self, from: data)
            guard (1...32).contains(result.streams.count), let raw = result.format.duration,
                  let seconds = Double(raw), seconds.isFinite, seconds > 0,
                  seconds * 1000 <= Double(V2ResourceTimedMediaMetadata.maximumDurationMilliseconds) else { throw V2ResourceTransformError.contentRejected }
            let video = result.streams.first { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }
            let dimensions: V2ResourceImageDimensions?
            switch kind {
            case .video:
                guard let video, let width = video.width, let height = video.height else { throw V2ResourceTransformError.contentRejected }
                dimensions = try .init(width: width, height: height)
            case .audio:
                guard video == nil, result.streams.contains(where: { $0.codec_type == "audio" }) else { throw V2ResourceTransformError.contentRejected }
                dimensions = nil
            }
            return try .init(kind: kind, durationMilliseconds: Int64((seconds * 1000).rounded(.up)), dimensions: dimensions)
        } catch { throw V2ResourceTransformError.contentRejected }
    }
}

// Foundation Process is only configured before publication. Launch/stop/final
// state are serialized by Mutex. The termination callback is the physical exit
// barrier; waitUntilExit can strand a detached thread's run loop on Darwin.
private final class V2BoundedMediaProbeProcess: @unchecked Sendable {
    private struct State { var cancelled = false; var timedOut = false; var finished = false }
    private let state = Mutex(State())
    private let process = Process()
    private let pipe = Pipe()
    private let termination: AsyncStream<Void>
    private let timeout: TimeInterval
    init(executable: URL, arguments: [String], input: FileHandle?, timeout: TimeInterval) {
        self.timeout = timeout
        let exit = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        termination = exit.stream
        process.terminationHandler = { _ in
            exit.continuation.yield(())
            exit.continuation.finish()
        }
        #if os(Linux)
        let memory = "ulimit -v 524288 || exit 78; "
        #else
        // Darwin rejects RLIMIT_DATA here and reserves a large dyld address map.
        // Linux production enforces aggregate address space; both enforce max_alloc/CPU/wall/output limits.
        let memory = ""
        #endif
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ulimit -t 15 || exit 78; ulimit -n 64 || exit 78; ulimit -f 128 || exit 78; " + memory + "exec \"$@\"", "im-v2-media-probe", executable.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"]
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    }
    private func stop(timedOut: Bool = false) {
        state.withLock { value in
            value.cancelled = true; value.timedOut = value.timedOut || timedOut
            if !value.finished, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    func run() async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try state.withLock { value in
                guard !value.cancelled else { throw CancellationError() }
                try process.run()
            }
            let deadline = Task { [self] in
                do { try await Task.sleep(for: .seconds(timeout)); stop(timedOut: true) } catch { }
            }
            let result = await Task.detached(priority: .utility) { [self] in
                var bytes = Data(), failed = false
                do {
                    while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                        guard bytes.count + chunk.count <= 65536 else { failed = true; stop(); break }
                        bytes.append(chunk)
                    }
                } catch { failed = true; stop() }
                return (bytes, failed)
            }.value
            // A detached waiter does not inherit caller cancellation: cancellation
            // requests SIGKILL, but must still await the actual process exit.
            await Task.detached { [termination] in
                for await _ in termination { break }
            }.value
            state.withLock { $0.finished = true }
            deadline.cancel(); _ = await deadline.result
            try Task.checkCancellation()
            if state.withLock({ $0.timedOut }) { throw V2ResourceProviderError.temporarilyUnavailable }
            guard !result.1 else { throw V2ResourceTransformError.contentRejected }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                if [78, 126, 127].contains(process.terminationStatus) { throw V2ResourceProviderError.configurationInvalid }
                throw V2ResourceTransformError.contentRejected
            }
            return result.0
        } onCancel: { [self] in stop() }
    }
}
