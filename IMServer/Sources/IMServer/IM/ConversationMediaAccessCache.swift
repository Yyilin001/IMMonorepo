import Foundation
import Vapor

actor ConversationMediaAccessCache {
    private struct Entry {
        let ownerUserID: UUID
        let conversationID: UUID
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private var entries: [String: Entry] = [:]
    private var keysByConversationID: [UUID: Set<String>] = [:]

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    func ownerUserID(assetID: String, userID: UUID, now: Date = Date()) -> UUID? {
        let key = Self.key(assetID: assetID, userID: userID)
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            removeEntry(for: key)
            return nil
        }
        return entry.ownerUserID
    }

    func store(assetID: String, userID: UUID, conversationID: UUID, ownerUserID: UUID, now: Date = Date()) {
        let key = Self.key(assetID: assetID, userID: userID)
        removeEntry(for: key)
        entries[key] = Entry(
            ownerUserID: ownerUserID,
            conversationID: conversationID,
            expiresAt: now.addingTimeInterval(ttl)
        )
        keysByConversationID[conversationID, default: []].insert(key)
    }

    func invalidate(assetID: String) {
        let prefix = "\(assetID.lowercased()):"
        for key in entries.keys where key.hasPrefix(prefix) {
            removeEntry(for: key)
        }
    }

    func invalidate(conversationID: UUID) {
        let keys = keysByConversationID[conversationID] ?? []
        for key in keys {
            removeEntry(for: key)
        }
        keysByConversationID[conversationID] = nil
    }

    private func removeEntry(for key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        keysByConversationID[entry.conversationID]?.remove(key)
        if keysByConversationID[entry.conversationID]?.isEmpty == true {
            keysByConversationID[entry.conversationID] = nil
        }
    }

    private static func key(assetID: String, userID: UUID) -> String {
        "\(assetID.lowercased()):\(userID.uuidString.lowercased())"
    }
}

private struct ConversationMediaAccessCacheStorageKey: StorageKey {
    typealias Value = ConversationMediaAccessCache
}

extension Application {
    var conversationMediaAccessCache: ConversationMediaAccessCache {
        get {
            if let cache = storage[ConversationMediaAccessCacheStorageKey.self] {
                return cache
            }
            let cache = ConversationMediaAccessCache()
            storage[ConversationMediaAccessCacheStorageKey.self] = cache
            return cache
        }
        set { storage[ConversationMediaAccessCacheStorageKey.self] = newValue }
    }
}
