import Foundation
import Vapor

actor ActiveConversationRouteLookupCache {
    struct Key: Hashable, Sendable {
        let conversationID: UUID
        let recipientUserIDs: [UUID]

        init(conversationID: UUID, recipientUserIDs: [UUID]) {
            self.conversationID = conversationID
            self.recipientUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }

    struct LookupResult: Sendable {
        let cached: [UUID: Set<String>]
        let missingUserIDs: [UUID]
    }

    struct ResolveResult: Sendable {
        let routes: [UUID: Set<String>]
        let cachedUserCount: Int
        let missedUserCount: Int
        let joinedInFlight: Bool
        let cacheHit: Bool
    }

    typealias MissingRoutesLoader = @Sendable (_ missingUserIDs: [UUID]) async throws -> [UUID: Set<String>]
    typealias ActiveConversationRoutesLoader = @Sendable () async throws -> [UUID: Set<String>]

    private struct UserKey: Hashable, Sendable {
        let conversationID: UUID
        let userID: UUID
    }

    private struct UserEntry: Sendable {
        let nodes: Set<String>
        let expiresAt: Date
    }

    private struct InFlightKey: Hashable, Sendable {
        let conversationID: UUID
        let missingUserIDs: [UUID]

        init(conversationID: UUID, missingUserIDs: [UUID]) {
            self.conversationID = conversationID
            self.missingUserIDs = Array(Set(missingUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }

    private struct ConversationEntry: Sendable {
        let routes: [UUID: Set<String>]
        let expiresAt: Date
    }

    private var entries: [UserKey: UserEntry] = [:]
    private var conversationEntries: [UUID: ConversationEntry] = [:]
    private var inFlightLoads: [InFlightKey: Task<[UUID: Set<String>], any Error>] = [:]
    private var inFlightConversationLoads: [UUID: Task<[UUID: Set<String>], any Error>] = [:]

    func routes(for key: Key, now: Date = Date()) -> [UUID: Set<String>]? {
        let lookup = lookup(
            conversationID: key.conversationID,
            recipientUserIDs: key.recipientUserIDs,
            now: now
        )
        guard lookup.missingUserIDs.isEmpty else {
            return nil
        }
        return lookup.cached
    }

    func lookup(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        now: Date = Date()
    ) -> LookupResult {
        let orderedUserIDs = dedupedSortedUserIDs(recipientUserIDs)
        guard !orderedUserIDs.isEmpty else {
            return LookupResult(cached: [:], missingUserIDs: [])
        }

        var cached: [UUID: Set<String>] = [:]
        cached.reserveCapacity(orderedUserIDs.count)
        var missingUserIDs: [UUID] = []
        missingUserIDs.reserveCapacity(orderedUserIDs.count)
        for userID in orderedUserIDs {
            let userKey = UserKey(conversationID: conversationID, userID: userID)
            guard let entry = entries[userKey] else {
                missingUserIDs.append(userID)
                continue
            }
            guard entry.expiresAt > now else {
                entries[userKey] = nil
                missingUserIDs.append(userID)
                continue
            }
            cached[userID] = entry.nodes
        }
        return LookupResult(cached: cached, missingUserIDs: missingUserIDs)
    }

    func store(
        _ routes: [UUID: Set<String>],
        for key: Key,
        ttlMilliseconds: Int,
        maxEntries: Int,
        now: Date = Date()
    ) {
        store(
            routes,
            conversationID: key.conversationID,
            requestedUserIDs: key.recipientUserIDs,
            ttlMilliseconds: ttlMilliseconds,
            maxEntries: maxEntries,
            now: now
        )
    }

    func store(
        _ routes: [UUID: Set<String>],
        conversationID: UUID,
        requestedUserIDs: [UUID],
        ttlMilliseconds: Int,
        maxEntries: Int,
        now: Date = Date()
    ) {
        let orderedUserIDs = dedupedSortedUserIDs(requestedUserIDs)
        guard ttlMilliseconds > 0, maxEntries > 0 else {
            for userID in orderedUserIDs {
                entries[UserKey(conversationID: conversationID, userID: userID)] = nil
            }
            return
        }
        guard !orderedUserIDs.isEmpty else {
            return
        }
        pruneExpired(now: now)
        let expiresAt = now.addingTimeInterval(TimeInterval(ttlMilliseconds) / 1000)
        for userID in orderedUserIDs {
            entries[UserKey(conversationID: conversationID, userID: userID)] = UserEntry(
                nodes: routes[userID] ?? [],
                expiresAt: expiresAt
            )
        }
        evictOldestEntries(over: maxEntries)
    }

    func resolve(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        ttlMilliseconds: Int,
        maxEntries: Int,
        now: Date = Date(),
        loader: @escaping MissingRoutesLoader
    ) async throws -> ResolveResult {
        let lookup = lookup(
            conversationID: conversationID,
            recipientUserIDs: recipientUserIDs,
            now: now
        )
        var routes = lookup.cached
        guard !lookup.missingUserIDs.isEmpty else {
            return ResolveResult(
                routes: routes,
                cachedUserCount: lookup.cached.count,
                missedUserCount: 0,
                joinedInFlight: false,
                cacheHit: true
            )
        }

        let inFlightKey = InFlightKey(
            conversationID: conversationID,
            missingUserIDs: lookup.missingUserIDs
        )
        if let inFlight = inFlightLoads[inFlightKey] {
            let fetchedRoutes = try await inFlight.value
            store(
                fetchedRoutes,
                conversationID: conversationID,
                requestedUserIDs: lookup.missingUserIDs,
                ttlMilliseconds: ttlMilliseconds,
                maxEntries: maxEntries,
                now: Date()
            )
            for (userID, nodeIDs) in fetchedRoutes {
                routes[userID] = nodeIDs
            }
            return ResolveResult(
                routes: routes,
                cachedUserCount: lookup.cached.count,
                missedUserCount: lookup.missingUserIDs.count,
                joinedInFlight: true,
                cacheHit: false
            )
        }

        let task = Task {
            try await loader(lookup.missingUserIDs)
        }
        inFlightLoads[inFlightKey] = task
        do {
            let fetchedRoutes = try await task.value
            inFlightLoads.removeValue(forKey: inFlightKey)
            store(
                fetchedRoutes,
                conversationID: conversationID,
                requestedUserIDs: lookup.missingUserIDs,
                ttlMilliseconds: ttlMilliseconds,
                maxEntries: maxEntries,
                now: Date()
            )
            for (userID, nodeIDs) in fetchedRoutes {
                routes[userID] = nodeIDs
            }
            return ResolveResult(
                routes: routes,
                cachedUserCount: lookup.cached.count,
                missedUserCount: lookup.missingUserIDs.count,
                joinedInFlight: false,
                cacheHit: false
            )
        } catch {
            inFlightLoads.removeValue(forKey: inFlightKey)
            throw error
        }
    }

    func resolveActiveConversation(
        conversationID: UUID,
        ttlMilliseconds: Int,
        maxEntries: Int,
        now: Date = Date(),
        loader: @escaping ActiveConversationRoutesLoader
    ) async throws -> ResolveResult {
        pruneExpired(now: now)
        if let entry = conversationEntries[conversationID], entry.expiresAt > now {
            return ResolveResult(
                routes: entry.routes,
                cachedUserCount: entry.routes.count,
                missedUserCount: 0,
                joinedInFlight: false,
                cacheHit: true
            )
        }

        if let inFlight = inFlightConversationLoads[conversationID] {
            let routes = try await inFlight.value
            storeConversationRoutes(
                routes,
                conversationID: conversationID,
                ttlMilliseconds: ttlMilliseconds,
                maxEntries: maxEntries,
                now: Date()
            )
            return ResolveResult(
                routes: routes,
                cachedUserCount: 0,
                missedUserCount: routes.count,
                joinedInFlight: true,
                cacheHit: false
            )
        }

        let task = Task {
            try await loader()
        }
        inFlightConversationLoads[conversationID] = task
        do {
            let routes = try await task.value
            inFlightConversationLoads.removeValue(forKey: conversationID)
            storeConversationRoutes(
                routes,
                conversationID: conversationID,
                ttlMilliseconds: ttlMilliseconds,
                maxEntries: maxEntries,
                now: Date()
            )
            return ResolveResult(
                routes: routes,
                cachedUserCount: 0,
                missedUserCount: routes.count,
                joinedInFlight: false,
                cacheHit: false
            )
        } catch {
            inFlightConversationLoads.removeValue(forKey: conversationID)
            throw error
        }
    }

    func removeAll() {
        entries = [:]
        conversationEntries = [:]
        inFlightLoads.removeAll()
        inFlightConversationLoads.removeAll()
    }

    private func dedupedSortedUserIDs(_ userIDs: [UUID]) -> [UUID] {
        Array(Set(userIDs)).sorted { $0.uuidString < $1.uuidString }
    }

    private func pruneExpired(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
        conversationEntries = conversationEntries.filter { $0.value.expiresAt > now }
    }

    private func evictOldestEntries(over maxEntries: Int) {
        guard entries.count > maxEntries else {
            return
        }
        let removeCount = entries.count - maxEntries
        let keysToRemove = entries
            .sorted { lhs, rhs in
                if lhs.value.expiresAt == rhs.value.expiresAt {
                    if lhs.key.conversationID == rhs.key.conversationID {
                        return lhs.key.userID.uuidString < rhs.key.userID.uuidString
                    }
                    return lhs.key.conversationID.uuidString < rhs.key.conversationID.uuidString
                }
                return lhs.value.expiresAt < rhs.value.expiresAt
            }
            .prefix(removeCount)
            .map(\.key)
        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
    }

    private func storeConversationRoutes(
        _ routes: [UUID: Set<String>],
        conversationID: UUID,
        ttlMilliseconds: Int,
        maxEntries: Int,
        now: Date
    ) {
        guard ttlMilliseconds > 0, maxEntries > 0 else {
            conversationEntries[conversationID] = nil
            return
        }
        pruneExpired(now: now)
        conversationEntries[conversationID] = ConversationEntry(
            routes: routes,
            expiresAt: now.addingTimeInterval(TimeInterval(ttlMilliseconds) / 1000)
        )
        evictOldestConversationEntries(over: maxEntries)
    }

    private func evictOldestConversationEntries(over maxEntries: Int) {
        var routeCount = conversationEntries.values.reduce(0) { $0 + conversationEntryWeight($1) }
        guard routeCount > maxEntries else {
            return
        }
        let keysToRemove = conversationEntries
            .sorted { lhs, rhs in
                if lhs.value.expiresAt == rhs.value.expiresAt {
                    return lhs.key.uuidString < rhs.key.uuidString
                }
                return lhs.value.expiresAt < rhs.value.expiresAt
            }
            .map(\.key)
        for key in keysToRemove {
            guard routeCount > maxEntries else {
                break
            }
            if let removed = conversationEntries.removeValue(forKey: key) {
                routeCount -= conversationEntryWeight(removed)
            }
        }
    }

    private func conversationEntryWeight(_ entry: ConversationEntry) -> Int {
        max(1, entry.routes.count)
    }
}

private struct ActiveConversationRouteLookupCacheStorageKey: StorageKey {
    typealias Value = ActiveConversationRouteLookupCache
}

extension Application {
    var activeConversationRouteLookupCache: ActiveConversationRouteLookupCache {
        if let cache = storage[ActiveConversationRouteLookupCacheStorageKey.self] {
            return cache
        }
        let cache = ActiveConversationRouteLookupCache()
        storage[ActiveConversationRouteLookupCacheStorageKey.self] = cache
        return cache
    }
}
