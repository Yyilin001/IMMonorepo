import Foundation
import IMV2ClientRuntime
import IMV2SharedRuntime
#if os(Android)
import IMV2SharedAndroid
#elseif canImport(Security)
import IMV2SharedApple
#endif
private struct Reply: Encodable, Sendable { let snapshot: SharedSnapshot?; let error: String? }
private final class Registry: Sendable {
    struct Client: Sendable { let runtime: SharedRuntime; var closed = false }
    struct Operation: Sendable { let client: Int64; var task: Task<Void, Never>?; var result: Data? }
    struct State { var next: Int64 = 1; var clients: [Int64: Client] = [:]; var operations: [Int64: Operation] = [:] }
    let state = V2Lock(initialState: State())
    func create(_ configuration: SharedConfiguration) -> Int64 {
        guard let runtime = try? SharedRuntime(configuration, platform: defaultSharedPlatform()) else { return 0 }
        return state.withLock { state in
            guard state.clients.count < 8, !state.clients.values.contains(where: { $0.runtime.ownershipKey == runtime.ownershipKey }) else { return 0 }
            let id = state.next; state.next += 1; state.clients[id] = .init(runtime: runtime); return id
        }
    }
    func submit(_ clientID: Int64, request: SharedRequest) -> Int64 {
        state.withLock { state in
            guard let client = state.clients[clientID], !client.closed, state.operations.count < 128 else { return 0 }
            let id = state.next; state.next += 1
            state.operations[id] = .init(client: clientID)
            let task = Task {
                let reply: Reply
                do { try Task.checkCancellation(); reply = .init(snapshot: try await client.runtime.execute(request), error: nil) }
                catch { reply = .init(snapshot: nil, error: sharedFailure(error).rawValue) }
                let encoded = (try? JSONEncoder().encode(reply)) ?? Data()
                let data = !encoded.isEmpty && encoded.count <= 8 * 1_048_576 ? encoded : Data("{\"error\":\"operationFailed\"}".utf8)
                self.state.withLock { state in
                    if request.operation == .close && reply.error == nil { state.clients[clientID]?.closed = true }
                    state.operations[id]?.result = data
                    state.operations[id]?.task = nil
                }
            }
            state.operations[id]?.task = task
            return id
        }
    }
}
private let registry = Registry()
private func decode<T: Decodable>(_ type: T.Type, _ pointer: UnsafePointer<UInt8>?, _ count: Int32) -> T? {
    guard let pointer, (1...1_048_576).contains(count) else { return nil }
    return try? JSONDecoder().decode(type, from: Data(bytes: pointer, count: Int(count)))
}
@_cdecl("im_shared_create") public func sharedCreate(_ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int64 {
    guard let configuration = decode(SharedConfiguration.self, bytes, count) else { return 0 }; return registry.create(configuration)
}
@_cdecl("im_shared_submit") public func sharedSubmit(_ client: Int64, _ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int64 {
    guard let request = decode(SharedRequest.self, bytes, count) else { return 0 }; return registry.submit(client, request: request)
}
@_cdecl("im_shared_poll") public func sharedPoll(_ id: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let data = registry.state.withLock({ $0.operations[id]?.result }) else { return nil }
    let bytes = Array(data) + [0]
    let result = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    for (index, byte) in bytes.enumerated() { result[index] = CChar(bitPattern: byte) }
    return result
}
@_cdecl("im_shared_cancel") public func sharedCancel(_ id: Int64) { registry.state.withLock { $0.operations[id]?.task }?.cancel() }
@_cdecl("im_shared_release") public func sharedRelease(_ id: Int64) -> Int32 {
    registry.state.withLock { state in
        guard state.operations[id]?.result != nil else { return 0 }; state.operations.removeValue(forKey: id); return 1
    }
}
@_cdecl("im_shared_release_client") public func sharedReleaseClient(_ id: Int64) -> Int32 {
    registry.state.withLock { state in
        guard state.clients[id]?.closed == true, !state.operations.values.contains(where: { $0.client == id }) else { return 0 }
        state.clients.removeValue(forKey: id); return 1
    }
}
@_cdecl("im_shared_active") public func sharedActive() -> Int32 { registry.state.withLock { Int32($0.operations.count) } }
@_cdecl("im_shared_clients") public func sharedClients() -> Int32 { registry.state.withLock { Int32($0.clients.count) } }
@_cdecl("im_shared_free") public func sharedFree(_ bytes: UnsafeMutablePointer<CChar>?) { bytes?.deallocate() }

private func defaultSharedPlatform() throws -> SharedPlatform {
    #if os(Android)
    return .android()
    #elseif canImport(Security)
    return .apple()
    #else
    throw SharedFailure.invalidConfiguration
    #endif
}
