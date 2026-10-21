import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import Logging
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reads immutable signed authorization files supplied by deployment tooling.
/// Startup replays them before opening transport; subsequent scans add trust.
/// Removing a file is not revocation and cannot undo already accepted trust.
package actor V2ActorTrustAdmissionSource {
    private let directory: String
    private let trust: V2ActorTrustStore
    private var pool: NIOThreadPool?
    private var worker: Task<Void, Never>?
    private var loading = false
    private var closed = false
    private var accepted: Set<Data> = []
    private var scanFailed = false
    private let logger = Logger(label: "IMV2TrustAdmission")

    package init(directory: String, trust: V2ActorTrustStore) throws {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw V2ActorAuthenticationError.invalidConfiguration
        }
        self.directory = directory; self.trust = trust
    }
    package func start() async throws {
        guard !closed, pool == nil else { throw V2ActorAuthenticationError.invalidConfiguration }
        let pool = NIOThreadPool(numberOfThreads: 1); pool.start(); self.pool = pool
        try await refresh()
        guard !closed else { throw V2ActorAuthenticationError.overloaded }
        worker = Task { await self.run() }
    }
    package func refresh() async throws {
        guard !closed, !loading, let pool else { throw V2ActorAuthenticationError.overloaded }
        loading = true
        defer { loading = false }
        let directory = directory, trust = trust, previous = accepted
        let newlyAccepted = try await pool.runIfActive {
            let documents = try Self.read(directory)
            var hashes = Set<Data>()
            for bytes in documents {
                let hash = Data(SHA256.hash(data: bytes))
                if !previous.contains(hash) {
                    let packet = try V2ActorProtobuf.decode(V2ActorSignedPacket.self, from: bytes)
                    try trust.admitAuthorizedServices(packet)
                }
                hashes.insert(hash)
            }
            return hashes
        }
        accepted = newlyAccepted
    }
    private func run() async {
        defer { worker = nil }
        while !closed, !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                try await refresh()
                if scanFailed { logger.notice("Trust admission source recovered"); scanFailed = false }
            } catch {
                if closed || Task.isCancelled { return }
                if !scanFailed { logger.error("Trust admission source scan rejected"); scanFailed = true }
            }
        }
    }
    package func stop(deadline: ContinuousClock.Instant) async throws -> Bool {
        closed = true; worker?.cancel()
        while (loading || worker != nil), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        guard !loading, worker == nil else { return false }
        if let pool { try await pool.shutdownGracefully(); self.pool = nil }
        return true
    }
    private static func read(_ directory: String) throws -> [Data] {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).filter { $0.pathExtension == "pb" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 256 else { throw V2ActorAuthenticationError.oversized }
        var total = 0, result: [Data] = []
        for file in files {
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw V2ActorAuthenticationError.invalidConfiguration }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_size > 0, status.st_size <= 524_288 else { throw V2ActorAuthenticationError.invalidConfiguration }
            let bytes = try handle.read(upToCount: 524_289) ?? Data()
            guard !bytes.isEmpty, bytes.count <= 524_288 else { throw V2ActorAuthenticationError.oversized }
            total += bytes.count
            guard total <= 16 * 1024 * 1024 else { throw V2ActorAuthenticationError.oversized }
            result.append(bytes)
        }
        return result
    }
}
