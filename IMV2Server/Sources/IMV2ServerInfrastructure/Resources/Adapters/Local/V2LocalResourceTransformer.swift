import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct V2LocalResourceTransformer: V2ResourceTransformer {
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
        guard Set(outputs.keys) == Set(sizes), input.byteCount <= 32 * 1_024 * 1_024 else { throw V2ResourceProviderError.unsupportedCapability }
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
            var total:Int64=0
            while let chunk=try await stream.next() {
                total += Int64(chunk.count)
                guard total <= input.byteCount else { throw V2ResourceProviderError.integrityMismatch }
                try await Task.detached(priority:.utility) { try handle.write(contentsOf:chunk) }.value
            }
            try handle.close()
            guard total==input.byteCount else { throw V2ResourceProviderError.integrityMismatch }
            let process=ResourceImageProcess(executable:executable,arguments:[inputURL.path,directory.path,recipe.rawValue])
            try await process.run()
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
                receipts.append(try .init(size:size,facts:facts))
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
private final class ResourceImageProcess: @unchecked Sendable {
    private let process:Process
    init(executable:URL,arguments:[String]) {
        process=Process();process.executableURL=executable;process.arguments=arguments
        process.standardInput=FileHandle.nullDevice
        process.standardOutput=FileHandle.nullDevice
        process.standardError=FileHandle.nullDevice
        process.environment=["PATH":"/usr/bin:/bin"]
    }
    private func stop() {
        guard process.isRunning else { return }
        if kill(-process.processIdentifier, SIGKILL) != 0 { process.terminate() }
    }
    func run() async throws {
        try process.run()
        let deadline=Task { [self] in
            try await Task.sleep(for:.seconds(20))
            stop()
        }
        defer { deadline.cancel() }
        try await withTaskCancellationHandler {
            await Task.detached(priority:.utility) { [self] in process.waitUntilExit() }.value
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw V2ResourceProviderError.unsupportedCapability }
        } onCancel: { [self] in stop() }
    }
}
