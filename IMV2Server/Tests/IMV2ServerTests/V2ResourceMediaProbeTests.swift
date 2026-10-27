import Foundation
import Crypto
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerInfrastructure
import IMV2ServerContracts
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Isolated media metadata from verified original bytes", .timeLimit(.minutes(2)))
struct V2ResourceMediaProbeTests {
    @Test func realWaveAndVideoHaveMeasuredMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"), binding: .init(id: "test", configurationRevision: 1))
        let probe = try V2LocalResourceMediaProbe(temporaryDirectory: root.appendingPathComponent("work"), maximumBytes: 1_048_576)
        try await probe.verifyReadiness()
        let wave = Self.wave()
        let facts = try await write(wave, storage: storage, root: root)
        let audio = try await probe.probe(facts, contentType: "audio/wav", storage: storage)
        #expect(audio.kind == .audio && audio.durationMilliseconds == 2000 && audio.dimensions == nil)
        let invalid = try V2StoredObjectFacts(reference: facts.reference, byteCount: facts.byteCount, sha256: Data(repeating: 0, count: 32))
        await #expect(throws: V2ResourceProviderError.integrityMismatch) { try await probe.probe(invalid, contentType: "audio/wav", storage: storage) }
        await #expect(throws: V2ResourceTransformError.contentRejected) { try await probe.probe(facts, contentType: "video/mp4", storage: storage) }
        let file = root.appendingPathComponent("clip.mp4")
        let generator = Process()
        generator.executableURL = V2LocalResourceMediaProbe.defaultExecutable.deletingLastPathComponent().appendingPathComponent("ffmpeg")
        generator.arguments = ["-hide_banner", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=64x48:r=10:d=0.5", "-an", "-c:v", "mpeg4", "-threads", "1", "-y", file.path]
        generator.standardInput = FileHandle.nullDevice; generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run(); await Task.detached { generator.waitUntilExit() }.value
        try #require(generator.terminationStatus == 0)
        let videoFacts = try await write(Data(contentsOf: file), storage: storage, root: root)
        let video = try await probe.probe(videoFacts, contentType: "video/mp4", storage: storage)
        #expect(video.kind == .video && video.durationMilliseconds == 500)
        #expect(video.dimensions == (try V2ResourceImageDimensions(width: 64, height: 48)))
        await #expect(throws: V2ResourceTransformError.contentRejected) { try await probe.probe(videoFacts, contentType: "audio/mp4", storage: storage) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path).isEmpty)
    }
    @Test(arguments: ["0", "-1", "NaN", "Infinity", "N/A", "2678401", "1e200"])
    func rejectsInvalidDurations(raw: String) {
        let bytes = Data("{\"streams\":[{\"codec_type\":\"audio\"}],\"format\":{\"duration\":\"\(raw)\"}}".utf8)
        #expect(throws: V2ResourceTransformError.contentRejected) { try V2LocalResourceMediaProbe.decode(bytes, kind: .audio) }
    }
    @Test func validatesDimensionKindAndUnsupportedPlaylists() throws {
        #expect(throws: V2ResourceTransformError.contentRejected) { try V2ResourceTimedMediaMetadata(kind: .audio, durationMilliseconds: 1, dimensions: .init(width: 1, height: 1)) }
        #expect(throws: V2ResourceTransformError.contentRejected) { try V2ResourceTimedMediaMetadata(kind: .video, durationMilliseconds: 1, dimensions: nil) }
        #expect(throws: V2ResourceTransformError.contentRejected) { try V2LocalResourceMediaProbe.format("audio/x-mpegurl") }
        let bytes = Data("{\"streams\":[{\"codec_type\":\"video\",\"width\":20000,\"height\":1}],\"format\":{\"duration\":\"1\"}}".utf8)
        #expect(throws: V2ResourceTransformError.contentRejected) { try V2LocalResourceMediaProbe.decode(bytes, kind: .video) }
        let roundTrip = try V2ResourceTimedMediaMetadata(kind: .audio, durationMilliseconds: 1, dimensions: nil)
        #expect(try JSONDecoder().decode(V2ResourceTimedMediaMetadata.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }
    @Test(arguments: [false, true]) func cancellationAndTimeoutDrainActualChild(timeout: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("pid"), executable = root.appendingPathComponent("probe")
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try Data("#!/bin/sh\nprintf '%s' \"$$\" > \(quotedMarker)\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"), binding: .init(id: "test", configurationRevision: 1))
        let facts = try await write(Self.wave(), storage: storage, root: root)
        let probe = try V2LocalResourceMediaProbe(executable: executable, temporaryDirectory: root.appendingPathComponent("work"), maximumBytes: 100_000, timeout: timeout ? 0.5 : 20)
        let task = Task { try await probe.probe(facts, contentType: "audio/wav", storage: storage) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var launchedPID: Int32?
        while launchedPID == nil {
            launchedPID = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init)
            if ContinuousClock.now >= deadline {
                task.cancel(); _ = await task.result
                Issue.record("Probe did not publish its process identity")
                return
            }
            await Task.yield()
        }
        let pid = try #require(launchedPID)
        if timeout { await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) { try await task.value } }
        else { task.cancel(); await #expect(throws: CancellationError.self) { try await task.value } }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("work").path).isEmpty)
    }
    private func write(_ bytes: Data, storage: V2LocalResourceStorage, root: URL) async throws -> V2StoredObjectFacts {
        let file = root.appendingPathComponent(UUID().uuidString); try bytes.write(to: file)
        return try await storage.write(storage.allocate(), byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)), bytes: V2LocalResourceStorage.stream(file: file))
    }
    static func wave() -> Data {
        var result = Data()
        func text(_ value: String) { result.append(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(32036)); text("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(8000)); number(UInt32(16000)); number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(32000)); result.append(Data(repeating: 0, count: 32000))
        return result
    }
}
