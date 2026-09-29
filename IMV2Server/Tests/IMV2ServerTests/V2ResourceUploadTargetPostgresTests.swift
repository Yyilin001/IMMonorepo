@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2ResourceUploadTargetPostgresTests {
    @Test("current upload targets preserve identity, validate adapters and recheck authority after signing",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["valid", "failure", "length", "checksum", "mode", "deadline", "expired", "revoked", "cancelled", "shortened", "task-cancelled"])
    func targetBoundary(scenario: String) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
            let binding = try V2StorageBinding(id: "independent-target", configurationRevision: 4)
            let storage = try V2LocalResourceStorage(root: root, binding: binding)
            let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
            let authorization = UploadTargetAuthority()
            let authDeadline = Date().addingTimeInterval(30)
            let store = PostgresV2ResourceLifecycleStore(database: database, authorizationExpiresAt: authDeadline,
                authorize: { _ in try await authorization.check() })
            let transport = UploadTargetAdapter(binding: binding)
            let service = try V2ResourceService(resolve: { home, _, user, callerDevice in
                #expect(home == .room(room) && user == actor && callerDevice == device)
                return store
            }, registry: registry, transports: [transport], maximumBytes: 1_024, allocate: { _ in try storage.allocate() })
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                usage: .messageAttachment(room), contentType: "text/plain", byteCount: 3,
                checksum: .init(value: String(repeating: "a", count: 64)))
            let session = try await service.create(request, actor: actor, device: device)
            let input = try V2ResourceUploadTargetsRequest(locator: session.locator, generation: session.generation)
            let before = try await snapshot(session: session.locator.sessionID.uuidValue!, sql: sql)
            await transport.configure(scenario: scenario) {
                switch scenario {
                case "revoked": await authorization.revoke()
                case "cancelled":
                    _ = try await store.cancel(session: session.locator.sessionID.uuidValue!, generation: session.generation,
                        actor: actor.uuidValue!, device: device.uuidValue!, now: Date())
                case "shortened":
                    try await sql.raw("UPDATE im_v2.resource_upload_sessions SET expires_at=clock_timestamp()-interval '1 second' WHERE session_id=\(bind: session.locator.sessionID.uuidValue!)").run()
                case "task-cancelled": withUnsafeCurrentTask { $0?.cancel() }
                default: break
                }
            }
            let operation = Task { try await service.targets(input, actor: actor, device: device) }
            switch scenario {
            case "valid":
                let plan = try #require(try await operation.value.first)
                #expect(plan.mode == .httpPut && plan.expectedByteCount == request.byteCount && plan.checksum == request.checksum)
                #expect(plan.expiresAt <= authDeadline && plan.expiresAt <= session.expiresAt)
            case "failure": await #expect(throws: UploadTargetFailure.unavailable) { _ = try await operation.value }
            case "revoked": await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { _ = try await operation.value }
            case "cancelled", "shortened", "expired":
                await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await operation.value }
            case "task-cancelled": await #expect(throws: CancellationError.self) { _ = try await operation.value }
            default: await #expect(throws: V2ResourceProviderError.integrityMismatch) { _ = try await operation.value }
            }
            #expect(await transport.calls == 1)
            if scenario == "cancelled" {
                #expect(try await service.status(session.locator, actor: actor, device: device).generation == 2)
                await #expect(throws: V2ResourceProviderError.preconditionFailed) { _ = try await service.targets(input, actor: actor, device: device) }
                #expect(await transport.calls == 1)
            } else if scenario != "shortened" {
                #expect(try await snapshot(session: session.locator.sessionID.uuidValue!, sql: sql) == before)
                if scenario != "revoked" {
                    // Renewing a successfully issued target or retrying a failed signing
                    // operation uses the same session, operation and generation.
                    await transport.configure(scenario: "valid", action: {})
                    let renewed = try #require(try await service.targets(input, actor: actor, device: device).first)
                    #expect(renewed.checksum == request.checksum && renewed.expiresAt <= authDeadline)
                    #expect(await transport.calls == 2)
                    #expect(try await snapshot(session: session.locator.sessionID.uuidValue!, sql: sql) == before)
                }
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private func snapshot(session: UUID, sql: any SQLDatabase) async throws -> String {
        struct Row: Decodable { let value: String }
        return try #require(try await sql.raw("SELECT to_jsonb(s)::text AS value FROM im_v2.resource_upload_sessions s WHERE session_id=\(bind: session)").first(decoding: Row.self)).value
    }
}

private actor UploadTargetAuthority {
    private var allowed = true
    func check() throws { if !allowed { throw V2MediaStoreError.uploadNotAuthorized } }
    func revoke() { allowed = false }
}

private enum UploadTargetFailure: Error { case unavailable }

private actor UploadTargetAdapter: V2UploadTransport {
    nonisolated let binding: V2StorageBinding
    nonisolated let capabilities = V2ResourceTransportCapabilities(modes: [.httpPut], maximumBytes: 1_024)
    private var scenario = "valid"
    private var action: @Sendable () async throws -> Void = {}
    private(set) var calls = 0
    init(binding: V2StorageBinding) { self.binding = binding }
    func configure(scenario: String, action: @escaping @Sendable () async throws -> Void) { self.scenario = scenario; self.action = action }
    func plan(mode: V2ResourceTransferMode, mediaID: MediaID, contentType: String, byteCount: Int64,
              checksum: V2ResourceChecksum, expiresAt: Date) async throws -> V2ResourceTransferPlan {
        calls += 1
        try await action()
        if scenario == "failure" { throw UploadTargetFailure.unavailable }
        return try .init(mode: scenario == "mode" ? .httpGet : mode,
            url: #require(URL(string: "https://independent-upload.invalid/\(mediaID.rawValue)/\(calls)")),
            headers: [.init(name: "X-Upload-Capability", value: "opaque")],
            expiresAt: scenario == "deadline" ? expiresAt.addingTimeInterval(1) : scenario == "expired" ? .distantPast : expiresAt,
            expectedByteCount: scenario == "length" ? byteCount + 1 : byteCount,
            checksum: scenario == "checksum" ? .init(value: String(repeating: "b", count: 64)) : checksum)
    }
    func completedBytes(mediaID: MediaID, byteCount: Int64) throws -> V2ResourceByteStream { throw UploadTargetFailure.unavailable }
    func importBytes(mediaID: MediaID, contentType: String, byteCount: Int64, bytes: V2ResourceByteStream) throws { throw UploadTargetFailure.unavailable }
    func abort(mediaID: MediaID) { Issue.record("issuing targets must not abort an upload") }
}
