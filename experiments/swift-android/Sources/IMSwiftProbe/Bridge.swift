import Foundation
import Synchronization
#if canImport(Android)
import Android
#else
import Darwin
#endif

struct ProbeInput: Decodable, Sendable {
    let operation: String
    var path: String?
    var url: String?
    var maximumBytes: Int?
    var deadlineMilliseconds: Int?
}

struct ProbeResult: Codable, Sendable {
    let outcome: String
    let values: [String: String]
}

// JNI holds numeric identities, never raw Swift object pointers. A handle cannot
// be released while its physical task is running. Polling is intentionally a
// small phase-one ABI, not the proposed production Flow/callback API.
private final class ProbeRegistry: Sendable {
    struct Entry: Sendable { var task: Task<Void, Never>?; var result: ProbeResult? }
    struct State: Sendable { var next: Int64 = 1; var entries: [Int64: Entry] = [:] }
    let state = Mutex(State())
    func start(_ input: ProbeInput) -> Int64 {
        state.withLock { state in
            let id = state.next
            state.next += 1
            state.entries[id] = Entry()
            let task = Task {
                let result: ProbeResult
                do { result = try await runProbe(input) }
                catch is CancellationError { result = .init(outcome: "cancelled", values: [:]) }
                catch { result = .init(outcome: "error", values: ["error": String(describing: error)]) }
                self.state.withLock { $0.entries[id]?.result = result }
            }
            state.entries[id]?.task = task
            return id
        }
    }
}
private let registry = ProbeRegistry()

@_cdecl("im_probe_start")
public func probeStart(_ input: UnsafePointer<UInt8>?, _ count: Int64) -> Int64 {
    guard let input, count > 0, count <= 65_536,
          let request = try? JSONDecoder().decode(ProbeInput.self, from: Data(bytes: input, count: Int(count))) else { return 0 }
    return registry.start(request)
}
@_cdecl("im_probe_poll")
public func probePoll(_ id: Int64) -> UnsafeMutablePointer<CChar>? {
    let result = registry.state.withLock { $0.entries[id]?.result }
    guard let result, let data = try? JSONEncoder().encode(result) else { return nil }
    return String(decoding: data, as: UTF8.self).withCString { strdup($0) }
}
@_cdecl("im_probe_cancel")
public func probeCancel(_ id: Int64) {
    let task = registry.state.withLock { $0.entries[id]?.task }
    task?.cancel()
}
@_cdecl("im_probe_release")
public func probeRelease(_ id: Int64) -> Int32 {
    registry.state.withLock {
        guard $0.entries[id]?.result != nil else { return 0 }
        $0.entries.removeValue(forKey: id)
        return 1
    }
}
@_cdecl("im_probe_active")
public func probeActive() -> Int32 { registry.state.withLock { Int32($0.entries.count) } }
@_cdecl("im_probe_free")
public func probeFree(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }

func runProbe(_ input: ProbeInput) async throws -> ProbeResult {
    try Task.checkCancellation()
    switch input.operation {
    case "android_credentials", "android_credential_load", "android_credential_delete", "android_tls", "android_tls_wait", "android_session":
        return try await androidPlatformProbe(input)
    case "dependencies":
        guard let path = input.path, !path.isEmpty else { throw ProbeFailure.assertion("missing database path") }
        return try dependenciesProbe(path: path)
    case "runtime": return try await runtimeProbe(input)
    case "runtime_http": return try await runtimeHTTPProbe(input)
    case "http": return try await httpProbe(input)
    case "sleep":
        try await Task.sleep(for: .seconds(60))
        return .init(outcome: "unexpectedCompletion", values: [:])
    case "stream":
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let producer = Task {
            defer { continuation.finish() }
            do {
                for value in 0..<6_000 { try Task.checkCancellation(); continuation.yield(value); try await Task.sleep(for: .milliseconds(10)) }
            } catch {}
        }
        continuation.onTermination = { _ in producer.cancel() }
        for await _ in stream { if Task.isCancelled { break } }
        producer.cancel()
        await producer.value
        try Task.checkCancellation()
        return .init(outcome: "streamFinished", values: [:])
    default: return .init(outcome: "error", values: ["error": "unknown operation"])
    }
}
