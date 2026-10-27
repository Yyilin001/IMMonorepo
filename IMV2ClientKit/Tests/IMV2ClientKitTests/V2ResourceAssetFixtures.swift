import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit

/// Repository tests arrange metadata only. Transfer/file-lifetime tests must use
/// importTestResourceSource below so every byte comes through the real owner.
extension GRDBV2LocalSyncStore {
    func seedMetadataResourceAsset(_ id: V2LocalResourceAssetID, request: V2ResourceUploadRequest, sharingFileOf sharedAsset: V2LocalResourceAssetID? = nil) async throws {
        let journal = await resourceFileJournal()
        if try journal.localAsset(id) != nil { return }
        let file: UUID
        if let sharedAsset {
            guard let existing = try journal.localAsset(sharedAsset), let existingFile = existing.fileID,
                  existing.checksum == request.checksum, existing.byteCount == request.byteCount else { throw V2ResourceStorageError.conflict }
            file = existingFile.value
        } else {
            file = UUID()
            // Sparse placeholder, deliberately NOT checksum-verified. Metadata
            // tests never read it; accidental real transfers must fail hashing.
            let url = URL(fileURLWithPath: databasePool.path).deletingLastPathComponent().appending(path: "resources/files/\(file.uuidString)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(request.byteCount)); try handle.close()
        }
        try await databasePool.write { db in
            let context: (String, String?)
            switch request.usage {
            case .messageAttachment(let room): context = ("messageDraft",room.rawValue)
            case .groupAvatar(let room): context = ("groupAvatar",room.rawValue)
            case .userAvatar: context = ("personalAvatar",nil)
            }
            if sharedAsset == nil { try db.execute(sql: "INSERT INTO v2_resource_files(file_id,checksum,byte_count,allocated_bytes,retention,state,last_access_at) VALUES(?,?,?,0,'original','published',0)",
                arguments: [file.uuidString,request.checksum.value,request.byteCount]) }
            try db.execute(sql: """
                INSERT INTO v2_resource_local_assets(asset_id,planned_file_id,file_id,display_name,content_type,byte_count,checksum,purpose,room_id,state,selection_active,created_at)
                VALUES(?,?,?,?,?,?,?,?,?,'published',1,0)
                """, arguments: [id.value.uuidString,UUID().uuidString,file.uuidString,request.displayName.value,request.contentType,request.byteCount,request.checksum.value,context.0,context.1])
            try db.execute(sql: "INSERT INTO v2_resource_file_consumers(consumer_id,file_id,kind) VALUES(?,?,'selection')", arguments: [id.value.uuidString,file.uuidString])
        }
    }
    func prepareMetadataResourceTransfer(id: UUID, request: V2ResourceUploadRequest, localAssetID: V2LocalResourceAssetID, now: Date = Date()) async throws -> V2ResourceTransferJob {
        try await seedMetadataResourceAsset(localAssetID, request: request)
        return try await prepareResourceTransfer(id: id, request: request, localAssetID: localAssetID, now: now)
    }
    func freezeMetadataSendIntent(_ intent: V2SendIntent, resources: [V2ResourcePreparedUpload] = [], imports: [UUID: V2ResourceImportRequest] = [:], now: Date = Date(), originalCreatedAt: Date? = nil) async throws {
        for resource in resources { try await seedMetadataResourceAsset(resource.localAssetID, request: resource.request) }
        try await freezeSendIntent(intent, resources: resources, imports: imports, now: now, originalCreatedAt: originalCreatedAt)
    }
    func freezeMetadataGroupAvatarUploadIntent(actorUserID: UserID, command: V2GroupAvatarCommand, uploadJobID: UUID,
                                               request: V2ResourceUploadRequest, localAssetID: V2LocalResourceAssetID, now: Date = Date()) async throws -> V2GroupAvatarIntent {
        try await seedMetadataResourceAsset(localAssetID, request: request)
        return try await freezeGroupAvatarUploadIntent(actorUserID: actorUserID, command: command, uploadJobID: uploadJobID, request: request, localAssetID: localAssetID, now: now)
    }
    func seedMetadataProfileSource(_ source: V2ProfileAvatarUpload, checksum: String = String(repeating: "a", count: 64)) async throws {
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: source.id), mediaID: .init(uuid: source.id), usage: .userAvatar,
            contentType: source.contentType, byteCount: source.byteCount, checksum: .init(value: checksum), displayName: .init(source.displayName))
        try await seedMetadataResourceAsset(source.localAssetID, request: request)
    }
    func testHeldAssetIDs() async throws -> Set<V2LocalResourceAssetID> {
        try await databasePool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT a.asset_id FROM v2_resource_local_assets a JOIN v2_resource_file_consumers c USING(file_id)").map {
                guard let uuid = UUID(uuidString: $0) else { throw V2ResourceStorageError.invalidRecord }; return .init(uuid)
            })
        }
    }
}

func makeResourceTestCenter(store: GRDBV2LocalSyncStore, root: URL) async throws -> V2ResourceCenter {
    let user = try await store.resourceFileJournal().accountID()
    return try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root, cacheDirectory: root.appending(path: "cache-scope")), store: store)
}

@discardableResult
func importTestResourceSource(center: V2ResourceCenter, source: URL, id: V2LocalResourceAssetID, request: V2ResourceUploadRequest) async throws -> V2LocalResourceAsset {
    let purpose: V2LocalResourceAssetPurpose
    switch request.usage {
    case .messageAttachment(let room): purpose = .messageDraft(room)
    case .groupAvatar(let room): purpose = .groupAvatar(room)
    case .userAvatar: purpose = .personalAvatar
    }
    let asset = try await center.importLocal(at: source, displayName: request.displayName, contentType: .init(request.contentType), purpose: purpose, id: id)
    guard asset.checksum == request.checksum, asset.byteCount == request.byteCount else { throw V2ResourceStorageError.integrityMismatch }
    return asset
}

/// Synthetic metadata only; byte-lifetime tests still import and hash real data.
func resourceDescriptorFixture(room: String, media: String, contentType: String, bytes: Int64,
                               name: String = "附件") throws -> V2ResourceDescriptor {
    try .init(key: .init(home: .room(.init(room)), mediaID: .init(media)), revision: 1,
        displayName: .init(name), contentType: contentType, byteCount: bytes,
        checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
}

func resourcePresentationWireFixture(room: String, media: String, contentType: String, bytes: Int64,
                                     name: String = "附件", descriptor: V2ResourceDescriptor? = nil) throws -> [String: Any] {
    let descriptor = try descriptor ?? resourceDescriptorFixture(room: room, media: media, contentType: contentType, bytes: bytes, name: name)
    return ["media_id": media, "kind": V2MediaPresentation.kind(forContentType: contentType).rawValue,
        "content_type": contentType, "byte_count": bytes,
        "resource_descriptor": try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor))]
}

// Metadata fixtures inject accepted server facts, without pretending to own a
// running HTTP operation. Production writes require a persisted execution owner.
extension GRDBV2LocalSyncStore {
    func seedResourceImportStatus(_ status: V2ResourceImportStatus, id: UUID) async throws {
        try await databasePool.write { try Self.saveResourceImport(status, id: id, db: $0) }
    }
}
