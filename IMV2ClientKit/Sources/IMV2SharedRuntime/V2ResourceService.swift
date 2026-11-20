import Foundation
import IMV2Core
import IMV2ClientRuntime

/// One account's business resource graph. Existing library/transfer/cache services retain
/// their typed APIs and physical-close guarantees; platforms inject only their I/O adapters.
public final class V2ResourceService: Sendable {
    public let accountID: UserID
    public let library: V2ResourceCenter
    public let uploads: V2ResourceTransferEngine
    public let downloads: V2ResourceDownloadCache
    public let groupAvatars: V2GroupAvatarService
    private let store: GRDBV2LocalSyncStore
    private let lifetime: V2DirectoryLifetime
    public init(accountID: UserID, store: GRDBV2LocalSyncStore, library: V2ResourceCenter,
                uploads: V2ResourceTransferEngine, downloads: V2ResourceDownloadCache, groupAvatars: V2GroupAvatarService) {
        self.accountID = accountID; self.store = store; self.library = library
        self.uploads = uploads; self.downloads = downloads; self.groupAvatars = groupAvatars
        lifetime = .init(onClose: {
            await groupAvatars.close(); await uploads.close(); await downloads.close(); await library.close()
        })
    }
    public func prepareUpload(id: UUID, localAssetID: V2LocalResourceAssetID, usage: V2ResourceUsage) async throws -> UUID {
        try await lifetime.run { [store, library, uploads] in
            if let existing = try await store.resourceTransfer(id: id) {
                guard existing.request.usage == usage, existing.localAssetID == localAssetID else { throw V2ResourceJournalError.conflict }
                return existing.id
            }
            guard let asset = try await library.localAsset(localAssetID), asset.availability == .local else { throw V2ResourceStorageError.unavailable }
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: id), mediaID: .init(uuid: id), usage: usage,
                contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum,
                clientModes: [.httpPartPut, .httpPut], displayName: asset.displayName, clientImageDimensions: asset.imageDimensions)
            _ = try await uploads.prepare(id: id, request: request, localAssetID: asset.id)
            return id
        }
    }
    public func send(_ intent: V2SendIntent, assets: [V2LocalResourceAssetID], messages: V2MessageService) async throws {
        try await lifetime.run { [library, uploads] in
            guard intent.attachmentJobIDs.count == assets.count else { throw V2ResourceJournalError.invalidRecord }
            var prepared: [V2ResourcePreparedUpload] = []
            for (id, localID) in zip(intent.attachmentJobIDs, assets) {
                try Task.checkCancellation()
                guard let asset = try await library.localAsset(localID), asset.availability == .local else { throw V2ResourceStorageError.unavailable }
                let request = try V2ResourceUploadRequest(operationID: .init(uuid: id), mediaID: .init(uuid: id), usage: .messageAttachment(intent.roomID),
                    contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum,
                    clientModes: [.httpPartPut, .httpPut], displayName: asset.displayName, clientImageDimensions: asset.imageDimensions)
                prepared.append(try .init(id: id, request: request, localAssetID: localID))
            }
            try await messages.sendPreparedAttachments(intent, resources: prepared, using: uploads)
        }
    }
    public func download(_ media: V2MediaReference, message: V2MediaMessageLocation? = nil) async throws -> V2ResourceCachedFile {
        try await lifetime.run { [library, downloads] in
            if let message { _ = try await library.prepareMessageDownload(mediaID: media.mediaID, message: message) }
            return try await downloads.download(media, message: message)
        }
    }
    public func handoffPreparedSends() async throws {
        try await lifetime.run { [store] in
            for intent in try await store.duePreparedSendIntents() {
                try Task.checkCancellation()
                do { _ = try await store.handOffSendIntent(intent.id) }
                catch is CancellationError { throw CancellationError() }
                catch V2ServerTimeAnchor.Failure.unavailable { try Task.checkCancellation(); try await store.deferPreparedSendIntent(intent.id, consumeAttempt: false) }
                catch { try Task.checkCancellation(); try await store.deferPreparedSendIntent(intent.id) }
            }
        }
    }
    public func runSendPreparation() async throws {
        try await lifetime.run { [self] in
            try await store.runResourcePreparation {
                try await self.handoffPreparedSends()
                try await self.uploads.releaseFinishedSources()
            }
        }
    }
    public func cancelSend(_ id: UUID) async throws {
        try await lifetime.run { [store, uploads] in
            if let intent = try await store.preparingSendIntent(id: id) {
                try await store.cancelSendIntent(id)
                for job in intent.attachmentJobIDs {
                    try Task.checkCancellation()
                    if try await store.resourceImport(id: job) != nil { try await store.requestImportCancellation(id: job) }
                    else { try await uploads.cancel(id: job) }
                }
            } else {
                try await store.abandonProvenUnsentSendIntent(id)
            }
            try await uploads.releaseFinishedSources()
        }
    }
    public func avatarBytes(_ grant: V2AvatarReadGrant) async throws -> Data {
        try await lifetime.run { [downloads] in
            try await grant.requireValid()
            guard (1...2_097_152).contains(grant.avatar.byteCount) else { throw V2ResourceStorageError.capacityExceeded }
            let file = try await downloads.avatar(grant)
            let lease = try await file.borrowFile()
            do {
                let bytes = try Data(contentsOf: lease.fileURL)
                try await grant.requireValid(); try Task.checkCancellation()
                guard bytes.count == grant.avatar.byteCount else { throw V2ResourceStorageError.integrityMismatch }
                await lease.release(); return bytes
            } catch { await lease.release(); throw error }
        }
    }
    public func close() async { await lifetime.close() }
}
