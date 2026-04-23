import Foundation
import Vapor

// 文件传输先走最小可用实现：每个用户只维护一份“最新上传文件”。
struct FileStorageService {
    struct StoredFile {
        let url: URL
        let fileName: String
        let contentType: String
        let data: Data
    }

    private struct StoredFileMetadata: Codable {
        let fileName: String
        let contentType: String
        let updatedAt: Date
    }

    private let app: Application
    private let fileManager = FileManager.default

    init(app: Application) {
        if app.fileStorageRootDirectory == nil {
            app.fileStorageRootDirectory = Self.makeDefaultRootDirectory(for: app.environment)
        }
        self.app = app
    }

    func prepareStorage() throws {
        try fileManager.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: demoDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: demoFileURL.path) {
            let data = Data("demo file for authenticated download".utf8)
            try data.write(to: demoFileURL, options: .atomic)
        }
    }

    func saveLatestUpload(
        for userID: UUID,
        body: Data,
        contentType: String?
    ) throws {
        let userDirectory = uploadsDirectory.appendingPathComponent(userID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)

        try body.write(to: uploadFileURL(for: userID), options: .atomic)

        let metadata = StoredFileMetadata(
            fileName: "latest-upload.bin",
            contentType: normalizedContentType(contentType),
            updatedAt: Date()
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataURL(for: userID), options: .atomic)
    }

    func latestFile(for userID: UUID) throws -> StoredFile {
        let uploadURL = uploadFileURL(for: userID)
        if fileManager.fileExists(atPath: uploadURL.path) {
            let data = try Data(contentsOf: uploadURL)
            let metadata = try loadMetadata(for: userID)
            return StoredFile(
                url: uploadURL,
                fileName: metadata?.fileName ?? "latest-upload.bin",
                contentType: metadata?.contentType ?? "application/octet-stream",
                data: data
            )
        }

        return try StoredFile(
            url: demoFileURL,
            fileName: "demo-download.bin",
            contentType: "application/octet-stream",
            data: Data(contentsOf: demoFileURL)
        )
    }

    private var rootDirectory: URL {
        app.fileStorageRootDirectory ?? Self.makeDefaultRootDirectory(for: app.environment)
    }

    private static var packageRoot: URL {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        return sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func makeDefaultRootDirectory(for environment: Environment) -> URL {
        if let override = Environment.get("FILE_STORAGE_DIRECTORY"), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if environment == .testing {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("imserver-file-storage-tests-\(UUID().uuidString)", isDirectory: true)
        }

        return packageRoot
            .appendingPathComponent("Storage", isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    private var uploadsDirectory: URL {
        rootDirectory.appendingPathComponent("uploads", isDirectory: true)
    }

    private var demoDirectory: URL {
        rootDirectory.appendingPathComponent("demo", isDirectory: true)
    }

    private var demoFileURL: URL {
        demoDirectory.appendingPathComponent("demo-download.bin", isDirectory: false)
    }

    private func uploadFileURL(for userID: UUID) -> URL {
        uploadsDirectory
            .appendingPathComponent(userID.uuidString, isDirectory: true)
            .appendingPathComponent("latest-upload.bin", isDirectory: false)
    }

    private func metadataURL(for userID: UUID) -> URL {
        uploadsDirectory
            .appendingPathComponent(userID.uuidString, isDirectory: true)
            .appendingPathComponent("latest-upload.json", isDirectory: false)
    }

    private func loadMetadata(for userID: UUID) throws -> StoredFileMetadata? {
        let metadataURL = metadataURL(for: userID)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        return try JSONDecoder().decode(
            StoredFileMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
    }

    private func normalizedContentType(_ contentType: String?) -> String {
        guard let contentType, !contentType.isEmpty else {
            return "application/octet-stream"
        }
        return contentType
    }
}

private struct FileStorageRootDirectoryKey: StorageKey {
    typealias Value = URL
}

private extension Application {
    var fileStorageRootDirectory: URL? {
        get { storage[FileStorageRootDirectoryKey.self] }
        set { storage[FileStorageRootDirectoryKey.self] = newValue }
    }
}
