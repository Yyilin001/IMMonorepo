import Foundation
import HTTPTypes
import IMV2Core
import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("Resource upload HTTP boundary")
struct V2ResourceRouteContractTests {
    @Test("every upload operation authenticates before decoding or resolving storage", arguments: ["", "/status", "/targets", "/finalize", "/cancel"])
    func authenticationPrecedesInput(path: String) async throws {
        try await withRoutes { app, boundary, _, device, _ in
            try await app.testing { client in
                for headers: HTTPFields in [[:], [.authorization: "Bearer test"], [HTTPField.Name("X-IM-Device-ID")!: device.rawValue]] {
                    let response = try await client.send(.post, headers: headers, to: URI(string: "v2/resource-uploads" + path), beforeSend: {
                        $0.headers[.contentType] = "application/json"
                        $0.body = .init(string: "{malformed")
                    })
                    #expect(response.status == .unauthorized)
                }
            }
            #expect(await boundary.calls.isEmpty)
        }
    }

    @Test("required resource facts are checked before any storage access", arguments: ["", "/status", "/targets", "/finalize", "/cancel"])
    func invalidInputDoesNotResolve(path: String) async throws {
        try await withRoutes { app, boundary, _, device, _ in
            try await app.testing { client in
                let response = try await client.send(.post, headers: headers(device), to: URI(string: "v2/resource-uploads" + path), beforeSend: {
                    $0.body = .init(string: "{}")
                })
                #expect(response.status == .badRequest)
            }
            #expect(await boundary.calls.isEmpty)
        }
    }

    @Test("authenticated actor and device reach every operation; caller-supplied identity cannot replace them", arguments: ["", "/status", "/targets", "/finalize", "/cancel"])
    func authenticatedIdentity(path: String) async throws {
        try await withRoutes { app, boundary, actor, device, room in
            let locator = V2ResourceUploadLocator(home: .room(room), sessionID: .init(uuid: UUID()))
            let encoder = JSONEncoder()
            let encoded: Data
            switch path {
            case "": encoded = try encoder.encode(V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                usage: .messageAttachment(room), contentType: "text/plain", byteCount: 3, checksum: .init(value: String(repeating: "a", count: 64))))
            case "/status": encoded = try encoder.encode(locator)
            case "/targets": encoded = try encoder.encode(V2ResourceUploadTargetsRequest(locator: locator, generation: 1))
            case "/finalize": encoded = try encoder.encode(V2ResourceUploadFinalizeRequest(locator: locator, generation: 1))
            default: encoded = try encoder.encode(V2ResourceUploadCancelRequest(locator: locator, generation: 1))
            }
            var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            json["actorUserID"] = UUID().uuidString
            json["deviceID"] = UUID().uuidString
            let data = try JSONSerialization.data(withJSONObject: json)
            try await app.testing { client in
                let response = try await client.send(.post, headers: headers(device), to: URI(string: "v2/resource-uploads" + path), beforeSend: {
                    $0.body = .init(data: data)
                })
                // The recording resolver rejects access. The HTTP boundary must not
                // reveal whether this is a missing object or a different owner.
                #expect(response.status == .notFound)
            }
            let calls = await boundary.calls
            try #require(calls.count == 1)
            #expect(calls[0].home == .room(room) && calls[0].actor == actor && calls[0].device == device)
            #expect(calls[0].usage == (path.isEmpty ? .messageAttachment(room) : nil))
        }
    }

    private func headers(_ device: DeviceID) -> HTTPFields {
        [.authorization: "Bearer test", .contentType: "application/json", HTTPField.Name("X-IM-Device-ID")!: device.rawValue]
    }

    private func withRoutes(_ body: (Application, ResourceRouteBoundary, UserID, DeviceID, RoomID) async throws -> Void) async throws {
        let app = try await Application(.testing)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
            let boundary = ResourceRouteBoundary()
            let binding = try V2StorageBinding(id: "contract", configurationRevision: 1)
            let storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"), binding: binding)
            let registry = try V2ResourceStorageRegistry(storages: [storage], defaultBinding: binding)
            let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root.appendingPathComponent("uploads"),
                targetBaseURL: #require(URL(string: "https://resource.invalid")), signingKey: Data(repeating: 1, count: 32))
            let service = try V2ResourceService(resolve: { home, usage, actor, device in
                try await boundary.resolve(home: home, usage: usage, actor: actor, device: device)
            }, registry: registry, transports: [V2LocalResourceUploadTransport(binding: binding, provider: provider)], maximumBytes: 100,
                allocate: { _ in Issue.record("rejected requests cannot allocate storage"); return try storage.allocate() })
            V2VaporResourceRoutes(authenticator: ResourceRouteAuthentication(actor: actor), service: service).register(on: app)
            try await body(app, boundary, actor, device, room)
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }
}

private struct ResourceRouteAuthentication: V2GatewayAuthenticator {
    let actor: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        #expect(accessToken == "test")
        return .init(userID: actor, expiresAt: nil)
    }
}

private actor ResourceRouteBoundary {
    struct Call: Sendable { let home: V2ResourceHome; let usage: V2ResourceUsage?; let actor: UserID; let device: DeviceID }
    private(set) var calls: [Call] = []
    func resolve(home: V2ResourceHome, usage: V2ResourceUsage?, actor: UserID, device: DeviceID) throws -> PostgresV2ResourceLifecycleStore {
        calls.append(.init(home: home, usage: usage, actor: actor, device: device))
        throw V2MediaStoreError.uploadNotAuthorized
    }
}
