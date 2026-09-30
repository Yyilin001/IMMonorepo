@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite(.serialized)
struct V2ResourceLogicalIdentityPostgresTests {
    @Test("attachment admission requires its room home and an active current generation",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["ready", "catalog-missing", "wrong-room", "avatar", "stale-generation", "retiring", "expired"])
    func attachmentAdmission(scenario: String) async throws {
        try await withFixture { f in
            try await f.sql.raw("UPDATE im_v2.resource_catalog SET home_kind='room',home_id=\(bind: f.room.uuidValue!),usage_kind='message_attachment' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            switch scenario {
            case "catalog-missing": try await f.sql.raw("DELETE FROM im_v2.resource_catalog WHERE media_id=\(bind: f.media.uuidValue!)").run()
            case "wrong-room": try await f.sql.raw("UPDATE im_v2.resource_catalog SET home_id=\(bind: UUID()) WHERE media_id=\(bind: f.media.uuidValue!)").run()
            case "avatar": try await f.sql.raw("UPDATE im_v2.resource_catalog SET usage_kind='group_avatar' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            case "stale-generation": try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind: f.media.uuidValue!)").run()
            case "retiring": try await f.sql.raw("UPDATE im_v2.resource_blob_placements SET state='retiring' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            case "expired": try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=clock_timestamp()-interval '1 second' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            default: break
            }
            let command = try V2SendMessageCommand(roomID: f.room, senderUserID: f.user,
                clientMessageID: .init(uuid: UUID()), text: "", media: [.init(mediaID: f.media)], limits: .init(maxUTF8Bytes: 128))
            let read: () async throws -> [V2MediaPresentation] = {
                try await RoomWriteMediaAcceptance.presentations(command: command, importedForward: nil,
                    forwardSourceRoomID: nil, senderID: f.user.uuidValue!, now: Date(), sql: f.sql)
            }
            if scenario == "ready" {
                let values = try await read()
                #expect(values.map(\.mediaID) == [f.media])
            } else { await #expect(throws: V2MediaStoreError.mediaUnavailable) { _ = try await read() } }
        }
    }

    @Test("an avatar cannot acquire a generic media grant, with or without a catalog entry",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil), arguments: [false, true])
    func avatarRequiresPresentationAuthorization(removeCatalog: Bool) async throws {
        try await withFixture { f in
            let handle = "av" + f.user.rawValue.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
            try await f.sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,avatar_media_id,created_at,updated_at) VALUES(\(bind: f.user.uuidValue!),\(bind: handle),'Avatar owner',\(bind: f.media.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            try await f.sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: f.user.uuidValue!),\(bind: f.device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            if removeCatalog { try await f.sql.raw("DELETE FROM im_v2.resource_catalog WHERE media_id=\(bind: f.media.uuidValue!)").run() }
            #expect(try await !V2PostgresMediaVisibilityAuthorization.isAuthorized(mediaID: f.media.uuidValue!,
                requesterUserID: f.user.uuidValue!, deviceID: f.device.uuidValue!, on: f.sql))
        }
    }

    @Test("downloads and scans require a registered resource even when physical bytes exist",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func catalogIsRequired() async throws {
        try await withFixture { f in
            let delivery = try V2LocalResourceDelivery(registry: f.registry,
                baseURL: #require(URL(string: "https://identity.test")), keyID: "test", keys: ["test": Data(repeating: 9, count: 32)])
            let downloads = try V2BoundMediaProvider(database: f.database, registry: f.registry, delivery: delivery, transports: [])
            let scanner = V2PlacementMediaScanner(database: f.database, registry: f.registry, scanner: V2LocalResourceScanner())
            _ = try await downloads.issueDownloadTarget(mediaID: f.media, expiresAt: Date().addingTimeInterval(60))
            try await f.sql.raw("DELETE FROM im_v2.resource_catalog WHERE media_id=\(bind: f.media.uuidValue!)").run()
            await #expect(throws: V2ResourceProviderError.notFound) {
                _ = try await downloads.issueDownloadTarget(mediaID: f.media, expiresAt: Date().addingTimeInterval(60))
            }
            await #expect(throws: V2ResourceProviderError.notFound) { _ = try await scanner.scan(mediaID: f.media) }
            #expect(try await f.localSource.inspect(f.old).sha256 == f.digest)
        }
    }

    @Test("avatar identity survives a verified location replacement",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func stableAvatarIdentity() async throws {
        try await withFixture { f in
            let delivery = IdentityDelivery()
            let reader = V2ResourceAvatarDelivery(delivery: delivery)
            let before = try await reader.authorizedAvatar(mediaID: f.media, database: f.database, expiresAt: Date().addingTimeInterval(60))
            #expect(before.variantID == f.variant)
            #expect(before.variantID.uuidValue != f.old.placementID)
            try await f.replaceLocation(variant: true)
            let after = try await reader.authorizedAvatar(mediaID: f.media, database: f.database, expiresAt: Date().addingTimeInterval(60))
            #expect(after.variantID == before.variantID && after.checksum == before.checksum && after.version == before.version)
            #expect(await delivery.references == [f.old, f.replacement])
            try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind: f.media.uuidValue!)").run()
            await #expect(throws: V2ResourceProviderError.notFound) {
                _ = try await reader.authorizedAvatar(mediaID: f.media, database: f.database, expiresAt: Date().addingTimeInterval(60))
            }
        }
    }

    @Test("an import retry uses its held input; new imports resolve the current logical identity",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil), arguments: [false, true])
    func heldInputSurvivesReplacement(variant: Bool) async throws {
        try await withFixture { f in
            let imports = try await f.imports()
            let request = try f.request(variant: variant)
            await f.source.failNextRead()
            await #expect(throws: V2ResourceProviderError.temporarilyUnavailable) {
                _ = try await imports.create(request, actor: f.user, device: f.device)
            }
            let before = try await f.hold(request)
            #expect(before.reference == f.old && before.bytes == f.bytes.count && before.sha256 == f.digest && before.released == nil)
            try await f.replaceLocation(variant: variant)
            // The old adapter is still needed only because of the persisted hold.
            try await f.sql.raw("DELETE FROM im_v2.resource_blob_placements WHERE media_id=\(bind: f.media.uuidValue!) AND reference_json=\(bind: identityJSON(f.old))::jsonb").run()
            if !variant { try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!)").run() }
            #expect(try await V2ResourceStorageReadiness.referencedBindings(database: f.database).contains(f.source.binding))
            let result = try await imports.create(request, actor: f.user, device: f.device)
            #expect(result.state == .processing)
            #expect(await f.source.reads == [f.old, f.old])
            let after = try await f.hold(request)
            #expect(after.reference == before.reference && after.sha256 == before.sha256 && after.released != nil)
            #expect(try await !V2ResourceStorageReadiness.referencedBindings(database: f.database).contains(f.source.binding))
            let row = try #require(try await f.sql.raw("SELECT reference_json::text AS reference FROM im_v2.resource_blob_placements WHERE media_id=\(bind: request.targetMediaID.uuidValue!)").first(decoding: IdentityReferenceRow.self))
            let output = try await f.target.inspect(JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8)))
            #expect(output.sha256 == f.digest && output.byteCount == f.bytes.count)
            // A second operation must use the replacement, with no read of the old source.
            let second = try f.request(variant: variant)
            _ = try await imports.create(second, actor: f.user, device: f.device)
            #expect(try await f.hold(second).reference == f.replacement)
            #expect(await f.source.reads == [f.old, f.old])
            // A physical placement UUID is not an alias for a new logical variant ID.
            if variant {
                let physical = try f.request(variant: true, variantID: .init(uuid: f.replacement.placementID))
                await #expect(throws: V2ResourceProviderError.notFound) { _ = try await imports.create(physical, actor: f.user, device: f.device) }
            }
            try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind: f.media.uuidValue!)").run()
            let stale = try f.request(variant: variant)
            await #expect(throws: V2ResourceProviderError.notFound) { _ = try await imports.create(stale, actor: f.user, device: f.device) }
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_import_holds WHERE operation_id=\(bind: stale.operationID.uuidValue!)").first() == nil)
        }
    }

    @Test("processor allocates independent logical IDs and preserves them on replay",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func processingReplay() async throws {
        try await withFixture { f in
            try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.media_objects SET state='scanning' WHERE media_id=\(bind: f.media.uuidValue!)").run()
            let transformer = IdentityTransformer()
            let processor = V2ResourceVariantProcessor(database: f.database, registry: f.registry, transformer: transformer,
                allocate: { _ in try f.localSource.allocate() })
            let input = try await f.localSource.inspect(f.old)
            try await processor.prepare(mediaID: f.media.uuidValue!, input: input)
            let first = try await f.sql.raw("SELECT variant_id::text AS value FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!) ORDER BY size").all(decoding: IdentityTextRow.self)
            #expect(first.count == 2 && Set(first.map(\.value)).count == 2)
            #expect(try await f.sql.raw("SELECT 1 FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!) AND variant_id=(reference_json->>'placementID')::uuid").first() == nil)
            try await processor.prepare(mediaID: f.media.uuidValue!, input: input)
            let second = try await f.sql.raw("SELECT variant_id::text AS value FROM im_v2.resource_variants WHERE media_id=\(bind: f.media.uuidValue!) ORDER BY size").all(decoding: IdentityTextRow.self)
            #expect(first == second)
            #expect(await transformer.calls == 1)
        }
    }

    private func withFixture(_ body: (ResourcePlacementTestFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resource-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let fixture = try await ResourcePlacementTestFixture(database: resources.database(.psql), root: root)
            try await body(fixture)
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

struct ResourcePlacementTestFixture: Sendable {
    let database: any Database; let sql: any SQLDatabase; let root: URL
    let user = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), media = MediaID(uuid: UUID())
    let room = RoomID(uuid: UUID()), variant = ResourceVariantID(uuid: UUID())
    let bytes: Data
    var digest: Data { Data(SHA256.hash(data: bytes)) }
    let localSource: V2LocalResourceStorage; let source: ResourcePlacementTestSource; let target: V2LocalResourceStorage
    let old: V2StoredObjectReference; let replacement: V2StoredObjectReference
    let registry: V2ResourceStorageRegistry
    init(database: any Database, root: URL, bytes: Data = Data("immutable input snapshot".utf8)) async throws {
        self.bytes = bytes
        self.database=database; self.sql=try #require(database as? any SQLDatabase); self.root=root
        let bindingA = try V2StorageBinding(id: "identity-a-" + UUID().uuidString, configurationRevision: 1)
        let bindingB = try V2StorageBinding(id: "identity-b-" + UUID().uuidString, configurationRevision: 2)
        localSource = try .init(root: root.appendingPathComponent("a"), binding: bindingA)
        source = .init(storage: localSource)
        target = try .init(root: root.appendingPathComponent("b"), binding: bindingB)
        old = try localSource.allocate(); replacement = try target.allocate()
        registry = try .init(storages: [source, target], defaultBinding: bindingB)
        let stream = IdentityBytes(bytes)
        _ = try await localSource.write(old, byteCount: Int64(bytes.count), sha256: digest, bytes: .init { await stream.next() })
        let copied = try await target.write(replacement, byteCount: Int64(bytes.count), sha256: digest, bytes: localSource.read(old))
        #expect(copied.sha256 == digest && copied.byteCount == bytes.count)
        try await sql.raw("INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at) VALUES(\(bind: media.uuidValue!),\(bind: user.uuidValue!),'image/png',\(bind: bytes.count),'available',\(bind: UUID()),clock_timestamp()+interval '1 hour',clock_timestamp(),clock_timestamp())").run()
        try await sql.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind: media.uuidValue!),'account',\(bind: user.uuidValue!),'user_avatar',clock_timestamp())").run()
        try await sql.raw("INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at) VALUES(\(bind: old.placementID),\(bind: media.uuidValue!),1,\(bind: identityJSON(old))::jsonb,\(bind: bytes.count),\(bind: digest),'active',clock_timestamp())").run()
        try await sql.raw("INSERT INTO im_v2.resource_variants(variant_id,media_id,generation,recipe,size,reference_json,byte_count,sha256,state,created_at) VALUES(\(bind: variant.uuidValue!),\(bind: media.uuidValue!),1,'avatar',128,\(bind: identityJSON(old))::jsonb,\(bind: bytes.count),\(bind: digest),'ready',clock_timestamp())").run()
    }
    func replaceLocation(variant: Bool) async throws {
        // Fixture-only switch: no production migration API is being exercised here.
        if variant {
            try await sql.raw("UPDATE im_v2.resource_variants SET reference_json=\(bind: identityJSON(replacement))::jsonb WHERE media_id=\(bind: media.uuidValue!)").run()
        } else {
            try await sql.raw("UPDATE im_v2.resource_blob_placements SET placement_id=\(bind: replacement.placementID),reference_json=\(bind: identityJSON(replacement))::jsonb WHERE media_id=\(bind: media.uuidValue!)").run()
        }
    }
    func request(variant: Bool, variantID: ResourceVariantID? = nil) throws -> V2ResourceImportRequest {
        try .init(operationID: .init(uuid: UUID()), source: variant
            ? .avatar(key: .init(userID: user, context: .relationship), mediaID: media, variantID: variantID ?? self.variant)
            : .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: media, variantID: nil),
            targetUsage: .messageAttachment(.init(uuid: UUID())), targetMediaID: .init(uuid: UUID()))
    }
    func imports(supportsAvatars: Bool = false) async throws -> V2ResourceImportService {
        let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root.appendingPathComponent("staging"),
            targetBaseURL: #require(URL(string: "https://identity.test")), signingKey: Data(repeating: 1, count: 32))
        try await provider.prepare()
        let transport = V2LocalResourceUploadTransport(binding: target.binding, provider: provider)
        let service = try V2ResourceService(resolve: { _,_,_,_ in PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in }) },
            registry: registry, transports: [transport], maximumBytes: 1_000_000,
            supportsAvatars: supportsAvatars, allocate: { _ in try target.allocate() })
        let observed = Date(), session = UUID()
        let authorization = V2ActorRoomMediaAuthorizationPort { query, _ in
            guard case .messageVisibility(let value) = query else { return .notVisible }
            return .visible(.init(roomID: value.roomID, messageID: value.messageID, mediaID: value.mediaID,
                membershipRevision: 1, contentRevision: 1, mediaUpdatedAt: observed, uploadSessionID: session))
        }
        let sources = V2ResourceImportSourceResolver(controlDatabase: database, rooms: IdentityRouter(),
            ownerDatabases: ["identity": database], authorization: authorization,
            avatarAuthorization: { _,_,_,_,_ in })
        let persistence = PostgresV2ResourceImportStore(resolve: { _,_,_,_ in
            PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
        }, sources: sources, recoveryDatabases: ["identity": database])
        return .init(resources: service, resolve: { _,_,_,_ in
            PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
        }, persistence: persistence, registry: registry, transports: [transport])
    }
    func hold(_ request: V2ResourceImportRequest) async throws -> (reference: V2StoredObjectReference, bytes: Int64, sha256: Data, released: Date?) {
        let row = try #require(try await sql.raw("SELECT reference_json::text AS reference,byte_count AS bytes,sha256,released_at AS released FROM im_v2.resource_import_holds WHERE actor_user_id=\(bind: user.uuidValue!) AND operation_id=\(bind: request.operationID.uuidValue!)").first(decoding: IdentityHold.self))
        return (try JSONDecoder().decode(V2StoredObjectReference.self, from: Data(row.reference.utf8)), row.bytes, row.sha256, row.released)
    }
}
private func identityJSON<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
private struct IdentityReferenceRow: Decodable { let reference: String }
private struct IdentityTextRow: Decodable, Equatable { let value: String }
private struct IdentityHold: Decodable { let reference: String; let bytes: Int64; let sha256: Data; let released: Date? }
private actor IdentityBytes {
    var data: Data?
    init(_ data: Data) { self.data=data }
    func next() -> Data? { defer { data=nil }; return data }
}
actor ResourcePlacementTestSource: V2ObjectStorage {
    nonisolated let binding: V2StorageBinding
    let storage: V2LocalResourceStorage
    private(set) var reads: [V2StoredObjectReference] = []
    var shouldFail = false
    init(storage: V2LocalResourceStorage) { self.storage=storage; self.binding=storage.binding }
    func failNextRead() { shouldFail=true }
    func inspect(_ reference: V2StoredObjectReference) async throws -> V2StoredObjectFacts { try await storage.inspect(reference) }
    func read(_ reference: V2StoredObjectReference) async throws -> V2ResourceByteStream {
        reads.append(reference)
        if shouldFail { shouldFail=false; throw V2ResourceProviderError.temporarilyUnavailable }
        return try await storage.read(reference)
    }
    func write(_ reference: V2StoredObjectReference, byteCount: Int64, sha256: Data, bytes: V2ResourceByteStream) async throws -> V2StoredObjectFacts {
        try await storage.write(reference, byteCount: byteCount, sha256: sha256, bytes: bytes)
    }
    func delete(_ reference: V2StoredObjectReference) async throws { try await storage.delete(reference) }
}
private actor IdentityDelivery: V2ResourceDelivery {
    private(set) var references: [V2StoredObjectReference] = []
    func issue(_ request: V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan {
        references.append(request.facts.reference)
        return try .init(mode: .httpGet, url: #require(URL(string: "https://identity.test/" + request.facts.reference.placementID.uuidString)),
            expiresAt: request.expiresAt, expectedByteCount: request.facts.byteCount,
            checksum: .init(value: request.facts.sha256.map { String(format: "%02x", $0) }.joined()))
    }
}
private actor IdentityTransformer: V2ResourceTransformer {
    private(set) var calls = 0
    func transform(input: V2StoredObjectFacts, recipe: V2ResourceRecipe, outputs: [Int: V2StoredObjectReference], registry: V2ResourceStorageRegistry) async throws -> [V2ResourceTransformOutput] {
        calls += 1
        var result: [V2ResourceTransformOutput] = []
        for (size, reference) in outputs {
            let facts = try await registry.storage(for: reference.binding).write(reference, byteCount: input.byteCount,
                sha256: input.sha256, bytes: registry.storage(for: input.reference.binding).read(input.reference))
            result.append(try .init(size: size, facts: facts))
        }
        return result
    }
}
private struct IdentityRouter: V2RoomShardRouting {
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute { try .init(shardID: "identity", epoch: 1) }
}
