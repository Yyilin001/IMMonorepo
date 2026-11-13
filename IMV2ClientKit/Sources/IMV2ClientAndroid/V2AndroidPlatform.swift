import Foundation
import Dispatch
import CIMV2AndroidPlatform
import IMV2ClientRuntime
import IMV2Core

struct PlatformFailure: Error { let status: Int32 }
enum AndroidBridge {
    static func call(_ operation: Int32, handle: Int64 = 0, name: String = "", data: Data = Data(), value: Int32 = 0) throws -> Data? {
        guard name.utf8.count <= 1024, name.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else { throw PlatformFailure(status: 6) }
        let result = name.withCString { name in
            data.withUnsafeBytes { bytes in
                im_v2_android_call(operation, handle, name, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, value)
            }
        }
        defer { im_v2_android_free(result) }
        if result.status == 1 { return nil }
        guard result.status == 0 else { throw PlatformFailure(status: result.status) }
        guard let bytes = result.bytes else { return Data() }
        return Data(bytes: bytes, count: result.count)
    }
    // The continuation completes only after the physical JNI operation has returned.
    static func io<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
    static func credentialError(_ error: any Error) -> V2CredentialStoreError {
        guard let failure = error as? PlatformFailure else { return .malformedRecord }
        switch failure.status {
        case 3: return .malformedRecord
        case 4: return .permanentlyInvalidated
        default: return .unavailable
        }
    }
}

/// One atomic, device-bound AES-GCM envelope, backed by Android Keystore and noBackupFilesDir.
/// Install AndroidRuntimePlatform after loading the containing native library before use.
/// Use a stable ASCII name (letters, digits, period, underscore or dash; 1...120 characters).
public final class V2AndroidCredentialStore: V2CredentialStore, Sendable {
    private let name: String
    private let queue = DispatchQueue(label: "im.android.credentials")
    public init(name: String = "auth") { self.name = name }
    public func load() async throws -> V2AuthCredentialRecord? {
        try await AndroidBridge.io(on: queue) { [name] in
            do {
                guard let data = try AndroidBridge.call(1, name: name) else { return nil }
                return try JSONDecoder().decode(V2AuthCredentialRecord.self, from: data)
            } catch { throw AndroidBridge.credentialError(error) }
        }
    }
    public func save(_ record: V2AuthCredentialRecord) async throws {
        try await AndroidBridge.io(on: queue) { [name] in
            do { _ = try AndroidBridge.call(2, name: name, data: JSONEncoder().encode(record)) }
            catch { throw AndroidBridge.credentialError(error) }
        }
    }
    public func delete() async throws {
        try await AndroidBridge.io(on: queue) { [name] in
            do { _ = try AndroidBridge.call(3, name: name) }
            catch { throw AndroidBridge.credentialError(error) }
        }
    }
}

/// Independent installation anchor for the shared GRDB bootstrapper.
public final class V2AndroidInstallationBindingStore: V2InstallationBindingStore, Sendable {
    private let name: String
    private let queue = DispatchQueue(label: "im.android.installation-binding")
    public init(name: String = "installation") { self.name = name }
    private func perform<T: Sendable>(_ body: @escaping @Sendable (String) throws -> T) async throws -> T {
        try await AndroidBridge.io(on: queue) { [name] in
            do { return try body(name) }
            catch {
                switch AndroidBridge.credentialError(error) {
                case .malformedRecord: throw V2InstallationBindingStoreError.malformedRecord
                case .permanentlyInvalidated: throw V2InstallationBindingStoreError.permanentlyInvalidated
                default: throw V2InstallationBindingStoreError.unavailable
                }
            }
        }
    }
    public func load() async throws -> V2LocalInstallationBinding? {
        try await perform { name in
            guard let data = try AndroidBridge.call(1, name: name) else { return nil }
            return try JSONDecoder().decode(V2LocalInstallationBinding.self, from: data)
        }
    }
    public func save(_ binding: V2LocalInstallationBinding) async throws {
        try await perform { name in _ = try AndroidBridge.call(2, name: name, data: JSONEncoder().encode(binding)) }
    }
    public func delete() async throws { try await perform { name in _ = try AndroidBridge.call(3, name: name) } }
}

/// TLS 1.3, platform trust and HTTPS hostname verification via Android SSLSocket.
/// Each instance is single-use. Cancellation closes the socket and drains blocking I/O.
public final class V2AndroidTLSByteConnection: V2TLSByteConnection, Sendable {
    private struct State { var handle: Int64?; var closed = false; var started = false }
    private let state = V2Lock(initialState: State())
    private let endpoint: V2RealtimeEndpoint
    private let readQueue = DispatchQueue(label: "im.android.tls.read")
    private let writeQueue = DispatchQueue(label: "im.android.tls.write")
    public init(endpoint: V2RealtimeEndpoint) { self.endpoint = endpoint }
    deinit { cancel() }

    public func start() async throws {
        try await cancellable(on: writeQueue) { [self] in
            let handle: Int64 = try state.withLock { state in
                guard !state.closed, !state.started else { throw V2TLSFrameConnectionError.connectionClosed }
                state.started = true
                guard let bytes = try AndroidBridge.call(10), bytes.count == 8 else { throw V2TLSFrameConnectionError.connectionFailed }
                let handle = bytes.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
                state.handle = handle
                return handle
            }
            _ = try AndroidBridge.call(11, handle: handle, name: endpoint.host, value: Int32(endpoint.port))
        }
    }
    public func send(_ data: Data) async throws {
        try await cancellable(on: writeQueue) { [self] in
            _ = try AndroidBridge.call(12, handle: activeHandle(), data: data)
        }
    }
    public func receive(maximumLength: Int) async throws -> Data {
        guard (1...1_048_576).contains(maximumLength) else { throw V2TLSFrameConnectionError.connectionFailed }
        return try await cancellable(on: readQueue) { [self] in
            try AndroidBridge.call(13, handle: activeHandle(), value: Int32(maximumLength)) ?? Data()
        }
    }
    private func activeHandle() throws -> Int64 {
        try state.withLock { state in
            guard !state.closed, let handle = state.handle else { throw V2TLSFrameConnectionError.connectionClosed }
            return handle
        }
    }
    private func cancellable<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let value = try await AndroidBridge.io(on: queue, body)
                try Task.checkCancellation()
                return value
            } catch {
                cancel()
                try Task.checkCancellation()
                if let error = error as? V2TLSFrameConnectionError { throw error }
                throw V2TLSFrameConnectionError.connectionFailed
            }
        } onCancel: { self.cancel() }
    }
    public func cancel() {
        let handle = state.withLock { state -> Int64? in
            state.closed = true
            defer { state.handle = nil }
            return state.handle
        }
        if let handle { _ = try? AndroidBridge.call(14, handle: handle) }
    }
}

/// Opaque encrypted ledgers for the shared registration/revocation/recovery owners.
/// The shared ledger owners serialize read-modify-write operations; this adapter serializes
/// individual Android storage calls process-wide. Call from a worker, never the UI thread.
public final class V2AndroidSecurePersistence: V2DeviceRevocationPersisting, V2DeviceRegistrationPersisting,
    V2IssuedCredentialRecoveryPersisting, Sendable {
    private let name: String
    public init(name: String) { self.name = name }
    public func load() throws -> Data? {
        do { return try AndroidBridge.call(1, name: name) }
        catch { throw AndroidBridge.credentialError(error) }
    }
    public func save(_ data: Data) throws {
        do { _ = try AndroidBridge.call(2, name: name, data: data) }
        catch { throw AndroidBridge.credentialError(error) }
    }
    public func delete() throws {
        do { _ = try AndroidBridge.call(3, name: name) }
        catch { throw AndroidBridge.credentialError(error) }
    }
}

/// Android wiring for the shared frame parser, handshake, request registry and cancellation owner.
/// Every connection generation receives a fresh single-use Android socket adapter.
extension V2TLSFrameConnection {
    public init(androidEndpoint: V2RealtimeEndpoint, frameLimits: V2FrameLimits,
                requestTimeout: Duration = .seconds(20), maximumPendingRequests: Int = 256,
                supportsAuthorPresentationDelta: Bool = false, workScheduler: V2AccountWorkScheduler? = nil,
                workService: String = "realtime") {
        self.init(connectionFactory: { V2AndroidTLSByteConnection(endpoint: androidEndpoint) },
                  frameLimits: frameLimits, requestTimeout: requestTimeout,
                  maximumPendingRequests: maximumPendingRequests,
                  supportsAuthorPresentationDelta: supportsAuthorPresentationDelta,
                  workScheduler: workScheduler, workService: workService)
    }
}
