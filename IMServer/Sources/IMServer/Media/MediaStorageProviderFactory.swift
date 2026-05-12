import Foundation
import Vapor

private struct MediaStorageRootDirectoryKey: StorageKey {
    typealias Value = URL
}

private struct MediaStorageProviderKey: StorageKey {
    typealias Value = any MediaStorageProvider
}

extension Application {
    var mediaStorageRootDirectory: URL? {
        get { storage[MediaStorageRootDirectoryKey.self] }
        set { storage[MediaStorageRootDirectoryKey.self] = newValue }
    }

    func requireMediaStorageProvider() throws -> any MediaStorageProvider {
        if let provider = storage[MediaStorageProviderKey.self] {
            return provider
        }
        let provider = try makeMediaStorageProvider()
        storage[MediaStorageProviderKey.self] = provider
        return provider
    }

    func makeMediaStorageProvider() throws -> any MediaStorageProvider {
        let providerName = (Environment.get("MEDIA_STORAGE_PROVIDER") ?? defaultMediaStorageProviderName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch providerName {
        case "local":
            if environment == .production {
                throw Abort(.internalServerError, reason: "Production requires MEDIA_STORAGE_PROVIDER=s3compatible.")
            }
            return LocalDiskMediaStorageProvider(app: self)
        case "s3compatible":
            return S3CompatibleMediaStorageProvider(
                app: self,
                configuration: try S3CompatibleMediaStorageProvider.Configuration.load(from: environment)
            )
        default:
            throw Abort(.internalServerError, reason: "Unsupported MEDIA_STORAGE_PROVIDER: \(providerName)")
        }
    }

    private var defaultMediaStorageProviderName: String {
        environment == .production ? "s3compatible" : "local"
    }
}
