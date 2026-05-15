import Foundation

enum ClientPersistenceStore {
    static let databaseFilename = "im-client-cache.sqlite"

    static func databaseURL() throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL.appending(path: "IMClientKit", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appending(path: databaseFilename, directoryHint: .notDirectory)
    }

    static func removeDatabase() throws {
        let url = try databaseURL()
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: candidate.path) {
                try fileManager.removeItem(at: candidate)
            }
        }
    }
}

public struct ClientPersistenceFactory: Sendable {
    private let databaseURLProvider: @Sendable () throws -> URL

    public init() {
        self.databaseURLProvider = {
            try ClientPersistenceStore.databaseURL()
        }
    }

    public init(databaseURLProvider: @escaping @Sendable () throws -> URL) {
        self.databaseURLProvider = databaseURLProvider
    }

    public func makeIMConversationCacheHandler() -> IMConversationCacheHandler {
        do {
            return IMConversationCacheHandler(
                try GRDBIMConversationCache(databaseURL: databaseURLProvider())
            )
        } catch {
            do {
                try ClientPersistenceStore.removeDatabase()
                return IMConversationCacheHandler(
                    try GRDBIMConversationCache(databaseURL: databaseURLProvider())
                )
            } catch {
                return IMConversationCacheHandler(NoopIMConversationCache())
            }
        }
    }

    public func makeContactStateCacheHandler() -> ContactStateCacheHandler {
        do {
            return ContactStateCacheHandler(
                try GRDBContactStateCache(databaseURL: databaseURLProvider())
            )
        } catch {
            do {
                try ClientPersistenceStore.removeDatabase()
                return ContactStateCacheHandler(
                    try GRDBContactStateCache(databaseURL: databaseURLProvider())
                )
            } catch {
                return ContactStateCacheHandler(NoopContactStateCache())
            }
        }
    }
}
