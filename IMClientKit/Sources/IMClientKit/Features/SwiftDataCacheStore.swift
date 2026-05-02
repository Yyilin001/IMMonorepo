import Foundation
import SwiftData

enum SwiftDataCacheStore {
    enum StoreKind {
        case imConversation
        case contactState

        var filename: String {
            switch self {
            case .imConversation:
                "im-conversation-cache.store"
            case .contactState:
                "contact-state-cache.store"
            }
        }
    }

    static func modelConfiguration(for kind: StoreKind, schema: Schema) throws -> ModelConfiguration {
        let url = try storeURL(filename: kind.filename)
        return ModelConfiguration(schema: schema, url: url)
    }

    static func removeStore(for kind: StoreKind) throws {
        let url = try storeURL(filename: kind.filename)
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
        }
    }

    private static func storeURL(filename: String) throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL.appending(path: "IMClientKit", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appending(path: filename, directoryHint: .notDirectory)
    }
}
