import Foundation
import Vapor

struct LocalDiskMediaStorageProvider: MediaStorageProvider {
    private let app: Application

    init(app: Application) {
        if app.mediaStorageRootDirectory == nil {
            app.mediaStorageRootDirectory = Self.makeDefaultRootDirectory(for: app.environment)
        }
        self.app = app
    }

    func prepareStorage() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
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
    ) async throws -> MediaStorageService.UploadSession {
        let normalizedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFilename.isEmpty else {
            throw Abort(.badRequest, reason: "文件名不能为空。")
        }
        guard byteSize > 0 else {
            throw Abort(.badRequest, reason: "文件大小必须大于 0。")
        }

        let uploadID = UUID().uuidString.lowercased()
        let session = MediaStorageService.UploadSession(
            uploadID: uploadID,
            ownerUserID: ownerUserID,
            kind: kind,
            mimeType: mimeType,
            byteSize: byteSize,
            filename: normalizedFilename,
            width: width,
            height: height,
            durationMillis: durationMillis,
            previewAssetID: previewAssetID,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        try persist(session)
        return session
    }

    func writeUploadChunk(
        uploadID: String,
        for ownerUserID: UUID,
        body: Data
    ) async throws {
        let fileManager = FileManager.default
        let session = try requireSession(uploadID: uploadID, ownerUserID: ownerUserID)
        guard Int64(body.count) == session.byteSize else {
            throw Abort(.badRequest, reason: "上传文件大小与预期不一致。")
        }

        let uploadDirectory = sessionDirectory(for: session.uploadID)
        try fileManager.createDirectory(at: uploadDirectory, withIntermediateDirectories: true)
        try body.write(to: chunkFileURL(for: session.uploadID), options: .atomic)
    }

    func completeUpload(
        uploadID: String,
        for ownerUserID: UUID
    ) async throws -> IMMediaAsset {
        let fileManager = FileManager.default
        let session = try requireSession(uploadID: uploadID, ownerUserID: ownerUserID)
        let chunkURL = chunkFileURL(for: session.uploadID)
        guard fileManager.fileExists(atPath: chunkURL.path) else {
            throw Abort(.badRequest, reason: "上传内容不存在，无法完成上传。")
        }

        let body = try Data(contentsOf: chunkURL)
        guard Int64(body.count) == session.byteSize else {
            throw Abort(.badRequest, reason: "上传文件大小与预期不一致。")
        }

        let storedAsset = MediaStorageService.StoredAsset(
            assetID: session.uploadID,
            ownerUserID: ownerUserID,
            kind: session.kind,
            mimeType: session.mimeType,
            byteSize: session.byteSize,
            filename: session.filename,
            width: session.width,
            height: session.height,
            durationMillis: session.durationMillis,
            previewAssetID: session.previewAssetID,
            createdAt: session.createdAt,
            storedAt: Date()
        )

        let assetDirectory = assetDirectory(for: ownerUserID)
        try fileManager.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try body.write(to: assetFileURL(for: ownerUserID, assetID: session.uploadID), options: .atomic)
        try JSONEncoder().encode(storedAsset).write(
            to: assetMetadataURL(for: ownerUserID, assetID: session.uploadID),
            options: .atomic
        )

        try removeSessionFiles(uploadID: session.uploadID)

        return IMMediaAsset(
            assetID: storedAsset.assetID,
            kind: storedAsset.kind,
            mimeType: storedAsset.mimeType,
            byteSize: storedAsset.byteSize,
            filename: storedAsset.filename,
            width: storedAsset.width,
            height: storedAsset.height,
            durationMillis: storedAsset.durationMillis,
            previewAssetID: storedAsset.previewAssetID
        )
    }

    func assetExists(ownerUserID: UUID, assetID: String) async -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: assetMetadataURL(for: ownerUserID, assetID: assetID).path)
    }

    func storedAsset(ownerUserID: UUID, assetID: String) async throws -> MediaStorageService.StoredAsset {
        let fileManager = FileManager.default
        let metadataURL = assetMetadataURL(for: ownerUserID, assetID: assetID)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw Abort(.notFound, reason: "附件不存在。")
        }

        return try JSONDecoder().decode(
            MediaStorageService.StoredAsset.self,
            from: Data(contentsOf: metadataURL)
        )
    }

    func storedAssetFile(ownerUserID: UUID, assetID: String) async throws -> MediaStorageService.StoredAssetFile {
        let fileManager = FileManager.default
        let metadata = try await storedAsset(ownerUserID: ownerUserID, assetID: assetID)
        let fileURL = assetFileURL(for: ownerUserID, assetID: assetID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw Abort(.notFound, reason: "附件内容不存在。")
        }

        return MediaStorageService.StoredAssetFile(
            metadata: metadata,
            fileURL: fileURL,
            data: try Data(contentsOf: fileURL)
        )
    }

    private var rootDirectory: URL {
        app.mediaStorageRootDirectory ?? Self.makeDefaultRootDirectory(for: app.environment)
    }

    private static var packageRoot: URL {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        return sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func makeDefaultRootDirectory(for environment: Environment) -> URL {
        if let override = Environment.get("MEDIA_STORAGE_DIRECTORY"), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if environment == .testing {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("imserver-media-storage-tests-\(UUID().uuidString)", isDirectory: true)
        }

        return packageRoot
            .appendingPathComponent("Storage", isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
    }

    private var sessionsDirectory: URL {
        rootDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    private var assetsDirectory: URL {
        rootDirectory.appendingPathComponent("assets", isDirectory: true)
    }

    private func sessionDirectory(for uploadID: String) -> URL {
        sessionsDirectory.appendingPathComponent(uploadID, isDirectory: true)
    }

    private func sessionMetadataURL(for uploadID: String) -> URL {
        sessionDirectory(for: uploadID).appendingPathComponent("session.json", isDirectory: false)
    }

    private func chunkFileURL(for uploadID: String) -> URL {
        sessionDirectory(for: uploadID).appendingPathComponent("chunk.bin", isDirectory: false)
    }

    private func assetDirectory(for ownerUserID: UUID) -> URL {
        assetsDirectory.appendingPathComponent(ownerUserID.uuidString, isDirectory: true)
    }

    private func assetMetadataURL(for ownerUserID: UUID, assetID: String) -> URL {
        assetDirectory(for: ownerUserID).appendingPathComponent("\(assetID).json", isDirectory: false)
    }

    private func assetFileURL(for ownerUserID: UUID, assetID: String) -> URL {
        assetDirectory(for: ownerUserID).appendingPathComponent("\(assetID).bin", isDirectory: false)
    }

    private func persist(_ session: MediaStorageService.UploadSession) throws {
        let fileManager = FileManager.default
        let directory = sessionDirectory(for: session.uploadID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(
            to: sessionMetadataURL(for: session.uploadID),
            options: .atomic
        )
    }

    private func requireSession(uploadID: String, ownerUserID: UUID) throws -> MediaStorageService.UploadSession {
        let session = try loadSession(uploadID: uploadID)
        guard session.ownerUserID == ownerUserID else {
            throw Abort(.notFound, reason: "上传会话不存在。")
        }
        guard session.expiresAt > Date() else {
            try? removeSessionFiles(uploadID: uploadID)
            throw Abort(.gone, reason: "上传会话已过期。")
        }
        return session
    }

    private func loadSession(uploadID: String) throws -> MediaStorageService.UploadSession {
        let fileManager = FileManager.default
        let metadataURL = sessionMetadataURL(for: uploadID)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw Abort(.notFound, reason: "上传会话不存在。")
        }

        return try JSONDecoder().decode(
            MediaStorageService.UploadSession.self,
            from: Data(contentsOf: metadataURL)
        )
    }

    private func removeSessionFiles(uploadID: String) throws {
        let fileManager = FileManager.default
        let directory = sessionDirectory(for: uploadID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }
}
