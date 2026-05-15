#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor

protocol MediaStorageProvider: Sendable {
    func prepareStorage() async throws
    func createUploadSession(
        for ownerUserID: UUID,
        kind: IMMediaAssetKind,
        mimeType: String,
        byteSize: Int64,
        filename: String,
        width: Int?,
        height: Int?,
        durationMillis: Int?,
        previewAssetID: String?
    ) async throws -> MediaStorageService.UploadSession
    func writeUploadChunk(
        uploadID: String,
        for ownerUserID: UUID,
        body: Data
    ) async throws
    func completeUpload(
        uploadID: String,
        for ownerUserID: UUID
    ) async throws -> IMMediaAsset
    func assetExists(ownerUserID: UUID, assetID: String) async -> Bool
    func storedAsset(ownerUserID: UUID, assetID: String) async throws -> MediaStorageService.StoredAsset
    func storedAssetFile(ownerUserID: UUID, assetID: String) async throws -> MediaStorageService.StoredAssetFile
}

struct MediaStorageService {
    struct UploadSession: Codable, Sendable {
        let uploadID: String
        let ownerUserID: UUID
        let kind: IMMediaAssetKind
        let mimeType: String
        let byteSize: Int64
        let filename: String
        let width: Int?
        let height: Int?
        let durationMillis: Int?
        let previewAssetID: String?
        let createdAt: Date
        let expiresAt: Date
    }

    struct StoredAsset: Codable, Sendable {
        let assetID: String
        let ownerUserID: UUID
        let kind: IMMediaAssetKind
        let mimeType: String
        let byteSize: Int64
        let filename: String
        let width: Int?
        let height: Int?
        let durationMillis: Int?
        let previewAssetID: String?
        let createdAt: Date
        let storedAt: Date
    }

    struct StoredAssetFile: Sendable {
        let metadata: StoredAsset
        let fileURL: URL
        let data: Data
    }

    private let provider: any MediaStorageProvider

    init(app: Application) throws {
        self.provider = try app.requireMediaStorageProvider()
    }

    func prepareStorage() async throws {
        try await provider.prepareStorage()
    }

    func createUploadSession(
        for ownerUserID: UUID,
        kind: IMMediaAssetKind,
        mimeType: String,
        byteSize: Int64,
        filename: String,
        width: Int?,
        height: Int?,
        durationMillis: Int?,
        previewAssetID: String?
    ) async throws -> UploadSession {
        try await provider.createUploadSession(
            for: ownerUserID,
            kind: kind,
            mimeType: mimeType,
            byteSize: byteSize,
            filename: filename,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID
        )
    }

    func writeUploadChunk(
        uploadID: String,
        for ownerUserID: UUID,
        body: Data
    ) async throws {
        try await provider.writeUploadChunk(uploadID: uploadID, for: ownerUserID, body: body)
    }

    func completeUpload(
        uploadID: String,
        for ownerUserID: UUID
    ) async throws -> IMMediaAsset {
        try await provider.completeUpload(uploadID: uploadID, for: ownerUserID)
    }

    func assetExists(ownerUserID: UUID, assetID: String) async -> Bool {
        await provider.assetExists(ownerUserID: ownerUserID, assetID: assetID)
    }

    func storedAsset(ownerUserID: UUID, assetID: String) async throws -> StoredAsset {
        try await provider.storedAsset(ownerUserID: ownerUserID, assetID: assetID)
    }

    func storedAssetFile(ownerUserID: UUID, assetID: String) async throws -> StoredAssetFile {
        try await provider.storedAssetFile(ownerUserID: ownerUserID, assetID: assetID)
    }
}
