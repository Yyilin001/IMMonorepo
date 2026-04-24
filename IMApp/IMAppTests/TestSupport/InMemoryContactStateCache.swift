import Foundation
@testable import IMClientKit
@testable import IMApp

actor InMemoryContactStateCache: ContactStateCaching {
    private var snapshotsByUserID: [UUID: ContactStateCacheSnapshot] = [:]
    private var saveCountsByUserID: [UUID: Int] = [:]

    func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        snapshotsByUserID[ownerUserID] ?? .empty
    }

    func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        snapshotsByUserID[ownerUserID] = snapshot
        saveCountsByUserID[ownerUserID, default: 0] += 1
    }

    func clearSnapshot(for ownerUserID: UUID) async throws {
        snapshotsByUserID.removeValue(forKey: ownerUserID)
        saveCountsByUserID.removeValue(forKey: ownerUserID)
    }

    func clearAll() async throws {
        snapshotsByUserID = [:]
        saveCountsByUserID = [:]
    }

    func seed(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) {
        snapshotsByUserID[ownerUserID] = snapshot
    }

    func latestSnapshot(for ownerUserID: UUID) -> ContactStateCacheSnapshot? {
        snapshotsByUserID[ownerUserID]
    }

    func saveCount(for ownerUserID: UUID) -> Int {
        saveCountsByUserID[ownerUserID, default: 0]
    }
}

actor FailingLoadContactStateCache: ContactStateCaching {
    enum Failure: Error {
        case loadFailed
    }

    func loadSnapshot(for ownerUserID: UUID) async throws -> ContactStateCacheSnapshot {
        _ = ownerUserID
        throw Failure.loadFailed
    }

    func saveSnapshot(_ snapshot: ContactStateCacheSnapshot, for ownerUserID: UUID) async throws {
        _ = snapshot
        _ = ownerUserID
    }

    func clearSnapshot(for ownerUserID: UUID) async throws {
        _ = ownerUserID
    }

    func clearAll() async throws { }
}
