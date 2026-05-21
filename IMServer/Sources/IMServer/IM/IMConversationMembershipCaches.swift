import Foundation

actor IMConversationMemberCache {
    private struct Entry {
        let context: IMCachedConversationMembership
        let expiresAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    func value(for conversationID: UUID, now: Date = Date()) -> IMCachedConversationMembership? {
        guard let entry = entries[conversationID] else { return nil }
        guard entry.expiresAt > now else {
            entries[conversationID] = nil
            return nil
        }
        return entry.context
    }

    func store(_ context: IMCachedConversationMembership, for conversationID: UUID, ttlSeconds: Int, now: Date = Date()) {
        guard ttlSeconds > 0 else { return }
        entries[conversationID] = Entry(
            context: context,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlSeconds))
        )
    }

    func invalidate(conversationID: UUID) {
        entries[conversationID] = nil
    }
}

actor IMDirectConversationPairCache {
    private struct Entry {
        let conversationIDs: [UUID]
        let expiresAt: Date
    }

    private let ttlSeconds: TimeInterval
    private var entries: [String: Entry] = [:]
    private var keysByConversationID: [UUID: Set<String>] = [:]

    init(ttlSeconds: TimeInterval = 5) {
        self.ttlSeconds = ttlSeconds
    }

    func conversationIDs(lhs: UUID, rhs: UUID, now: Date = Date()) -> [UUID]? {
        let key = Self.key(lhs: lhs, rhs: rhs)
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            removeEntry(for: key)
            return nil
        }
        return entry.conversationIDs
    }

    func store(_ conversationIDs: [UUID], lhs: UUID, rhs: UUID, now: Date = Date()) {
        let key = Self.key(lhs: lhs, rhs: rhs)
        removeEntry(for: key)
        entries[key] = Entry(
            conversationIDs: conversationIDs,
            expiresAt: now.addingTimeInterval(ttlSeconds)
        )
        for conversationID in conversationIDs {
            keysByConversationID[conversationID, default: []].insert(key)
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
        for conversationID in entry.conversationIDs {
            keysByConversationID[conversationID]?.remove(key)
            if keysByConversationID[conversationID]?.isEmpty == true {
                keysByConversationID[conversationID] = nil
            }
        }
    }

    private static func key(lhs: UUID, rhs: UUID) -> String {
        [lhs.uuidString.lowercased(), rhs.uuidString.lowercased()].sorted().joined(separator: ":")
    }
}
