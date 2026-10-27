import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import Crypto
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct V2LocalResourceTransformer: V2ResourceTransformer {
    public static let maximumInputBytes: Int64 = 32 * 1_024 * 1_024
    private let executable: URL
    private let temporaryDirectory: URL
    public init(executable: URL, temporaryDirectory: URL) throws {
        guard executable.isFileURL, temporaryDirectory.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw V2ResourceProviderError.configurationInvalid }
        self.executable=executable; self.temporaryDirectory=temporaryDirectory
    }
    public func verifyReadiness() async throws {
        try await ResourceImageProcess(executable: executable, arguments: ["--check"]).run()
    }
    public func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe,
                          outputs: [Int: V2StoredObjectReference], registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput] {
        let sizes = recipe == .avatar ? [128,256] : [320,1280]
        guard Set(outputs.keys) == Set(sizes) else { throw V2ResourceProviderError.configurationInvalid }
        guard input.byteCount <= Self.maximumInputBytes else { throw V2ResourceTransformError.contentRejected }
        let directory=temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let inputURL=directory.appendingPathComponent("input")
        try await Task.detached(priority:.utility) {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }.value
        do {
            let source=try registry.storage(for:input.reference.binding)
            let stream=try await source.read(input.reference)
            // A service-owned input is copied in bounded chunks. Decoder never receives storage credentials.
            let handle=try FileHandle(forWritingTo: createFile(inputURL))
            defer { try? handle.close() }
            var total:Int64=0
            var digest = SHA256()
            while let chunk=try await stream.next() {
                digest.update(data: chunk)
                total += Int64(chunk.count)
                guard total <= input.byteCount else { throw V2ResourceProviderError.integrityMismatch }
                try await Task.detached(priority:.utility) { try handle.write(contentsOf:chunk) }.value
            }
            try handle.close()
            guard total==input.byteCount, Data(digest.finalize()) == input.sha256 else { throw V2ResourceProviderError.integrityMismatch }
            let process=ResourceImageProcess(executable:executable,arguments:[inputURL.path,directory.path,recipe.rawValue])
            try await process.run()
            let dimensions = try await Task.detached(priority: .utility) {
                let file = directory.appendingPathComponent("source-dimensions.json")
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let count = attributes[.size] as? NSNumber, (1...128).contains(count.intValue),
                      attributes[.type] as? FileAttributeType == .typeRegular else { throw V2ResourceProviderError.integrityMismatch }
                return try JSONDecoder().decode(V2ResourceImageDimensions.self, from: Data(contentsOf: file))
            }.value
            var receipts:[V2ResourceTransformOutput]=[]
            for size in sizes {
                let file=directory.appendingPathComponent("\(size).png")
                let measurement=try await Task.detached(priority:.utility) {
                    let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
                    guard let count=attributes[.size] as? NSNumber, count.int64Value > 0,
                          count.int64Value <= (recipe == .avatar ? 512 * 1_024 : 8 * 1_024 * 1_024) else { throw V2ResourceProviderError.integrityMismatch }
                    return (count.int64Value,try ForwardMediaFileIO.digest(file,byteCount:count.int64Value))
                }.value
                let reference=outputs[size]!
                let outputStorage=try registry.storage(for:reference.binding)
                let facts=try await outputStorage.write(reference,byteCount:measurement.0,sha256:measurement.1,bytes:V2LocalResourceStorage.stream(file:file))
                receipts.append(try .init(size:size,facts:facts,sourceDimensions:dimensions))
            }
            await remove(directory)
            return receipts
        } catch { await remove(directory); throw error }
    }
    private func createFile(_ url:URL) throws -> URL {
        try Data().write(to:url,options:.withoutOverwriting)
        return url
    }
    private func remove(_ url:URL) async {
        await Task.detached(priority:.utility) { try? FileManager.default.removeItem(at:url) }.value
    }
}
// Process configuration precedes publication. Mutex serializes launch/stop;
// terminationHandler is the actual exit barrier. waitUntilExit on a detached
// Darwin thread can remain in its run loop after the child has already exited.
private final class ResourceImageProcess: @unchecked Sendable {
    private struct State { var cancelled = false; var timedOut = false; var finished = false }
    private let state = Mutex(State())
    private let process:Process
    private let termination: AsyncStream<Void>
    init(executable:URL,arguments:[String]) {
        let exit = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        termination = exit.stream
        process=Process();process.executableURL=executable;process.arguments=arguments
        process.terminationHandler = { _ in
            exit.continuation.yield(())
            exit.continuation.finish()
        }
        process.standardInput=FileHandle.nullDevice
        process.standardOutput=FileHandle.nullDevice
        process.standardError=FileHandle.nullDevice
        process.environment=["PATH":"/usr/bin:/bin"]
    }
    private func stop(timedOut: Bool = false) {
        state.withLock { value in
            value.cancelled = true
            value.timedOut = value.timedOut || timedOut
            guard !value.finished, process.isRunning else { return }
            if kill(-process.processIdentifier, SIGKILL) != 0 { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try state.withLock { value in
                guard !value.cancelled else { throw CancellationError() }
                try process.run()
            }
            let deadline = Task { [self] in
                do { try await Task.sleep(for: .seconds(20)); stop(timedOut: true) } catch { }
            }
            // Caller cancellation kills the owned child but must not cancel
            // this wait before physical termination has been acknowledged.
            await Task.detached { [termination] in
                for await _ in termination { break }
            }.value
            state.withLock { $0.finished = true }
            deadline.cancel(); _ = await deadline.result
            try Task.checkCancellation()
            if state.withLock({ $0.timedOut }) { throw V2ResourceProviderError.temporarilyUnavailable }
            guard process.terminationReason == .exit else { throw V2ResourceProviderError.temporarilyUnavailable }
            switch process.terminationStatus {
            case 0: return
            case 3, 4: throw V2ResourceTransformError.contentRejected
            case 2, 78: throw V2ResourceProviderError.configurationInvalid
            default: throw V2ResourceProviderError.temporarilyUnavailable
            }
        } onCancel: { [self] in stop() }
    }
}
