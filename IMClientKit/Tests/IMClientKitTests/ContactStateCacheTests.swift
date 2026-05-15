import Foundation
@testable import IMClientKit
import Testing

struct ContactStateCacheTests {
    @Test func snapshotRoundTripPreservesContactsRequestsAndRefreshTime() async throws {
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let cache = try makeCache()
        let snapshot = ContactStateCacheSnapshot(
            contacts: [
                CachedContactState(
                    id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                    email: "friend@example.com",
                    remark: "好友",
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ],
            incomingRequests: [
                CachedContactRequestState(
                    id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                    requester: AuthUser(
                        id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
                        email: "incoming@example.com"
                    ),
                    addressee: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    status: .pending,
                    message: "hi",
                    requesterRemark: "来加我",
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001),
                    respondedAt: nil
                )
            ],
            outgoingRequests: [
                CachedContactRequestState(
                    id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                    requester: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    addressee: AuthUser(
                        id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
                        email: "outgoing@example.com"
                    ),
                    status: .pending,
                    message: nil,
                    requesterRemark: "我自己",
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_002),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_002),
                    respondedAt: nil
                )
            ],
            resolvedRequests: [
                CachedContactRequestState(
                    id: UUID(uuidString: "99999999-eeee-eeee-eeee-eeeeeeeeeeee")!,
                    requester: AuthUser(
                        id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
                        email: "resolved@example.com"
                    ),
                    addressee: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    status: .accepted,
                    message: "done",
                    requesterRemark: nil,
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_003),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_004),
                    respondedAt: Date(timeIntervalSince1970: 1_700_300_005)
                )
            ],
            lastRefreshAt: Date(timeIntervalSince1970: 1_700_300_100),
            lastSeenIncomingContactRequestAt: Date(timeIntervalSince1970: 1_700_300_050)
        )

        try await cache.saveSnapshot(snapshot, for: ownerUserID)
        let restored = try await cache.loadSnapshot(for: ownerUserID)

        #expect(restored == snapshot)
    }

    @Test func clearSnapshotOnlyRemovesTargetOwner() async throws {
        let firstOwner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondOwner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cache = try makeCache()

        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: firstOwner), for: firstOwner)
        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: secondOwner), for: secondOwner)

        try await cache.clearSnapshot(for: firstOwner)

        #expect(try await cache.loadSnapshot(for: firstOwner) == .empty)
        #expect(try await cache.loadSnapshot(for: secondOwner) == sampleSnapshot(ownerUserID: secondOwner))
    }

    @Test func clearAllRemovesAllOwners() async throws {
        let firstOwner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondOwner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cache = try makeCache()

        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: firstOwner), for: firstOwner)
        try await cache.saveSnapshot(sampleSnapshot(ownerUserID: secondOwner), for: secondOwner)

        try await cache.clearAll()

        #expect(try await cache.loadSnapshot(for: firstOwner) == .empty)
        #expect(try await cache.loadSnapshot(for: secondOwner) == .empty)
    }

    @Test func saveSnapshotPersistsPendingAndResolvedRequests() async throws {
        let ownerUserID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let cache = try makeCache()
        let snapshot = ContactStateCacheSnapshot(
            contacts: [],
            incomingRequests: [
                CachedContactRequestState(
                    id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                    requester: AuthUser(
                        id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
                        email: "pending@example.com"
                    ),
                    addressee: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    status: .pending,
                    message: nil,
                    requesterRemark: nil,
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001),
                    respondedAt: nil
                ),
                CachedContactRequestState(
                    id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                    requester: AuthUser(
                        id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
                        email: "accepted@example.com"
                    ),
                    addressee: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    status: .accepted,
                    message: nil,
                    requesterRemark: nil,
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_002),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_003),
                    respondedAt: Date(timeIntervalSince1970: 1_700_300_004)
                )
            ],
            outgoingRequests: [],
            resolvedRequests: [
                CachedContactRequestState(
                    id: UUID(uuidString: "abababab-eeee-eeee-eeee-eeeeeeeeeeee")!,
                    requester: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    addressee: AuthUser(
                        id: UUID(uuidString: "cdcdcdcd-ffff-ffff-ffff-ffffffffffff")!,
                        email: "cancelled@example.com"
                    ),
                    status: .cancelled,
                    message: nil,
                    requesterRemark: nil,
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_006),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_007),
                    respondedAt: Date(timeIntervalSince1970: 1_700_300_008)
                )
            ],
            lastRefreshAt: Date(timeIntervalSince1970: 1_700_300_100),
            lastSeenIncomingContactRequestAt: nil
        )

        try await cache.saveSnapshot(snapshot, for: ownerUserID)
        let restored = try await cache.loadSnapshot(for: ownerUserID)

        #expect(restored.incomingRequests.count == 2)
        #expect(Set(restored.incomingRequests.map(\.status)) == Set([.pending, .accepted]))
        #expect(restored.resolvedRequests.map(\.status) == [.cancelled])
    }

    private func makeCache() throws -> GRDBContactStateCache {
        try GRDBContactStateCache(databaseURL: temporaryDatabaseURL())
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "IMClientKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "cache.sqlite", directoryHint: .notDirectory)
    }

    private func sampleSnapshot(ownerUserID: UUID) -> ContactStateCacheSnapshot {
        ContactStateCacheSnapshot(
            contacts: [
                CachedContactState(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    email: "\(ownerUserID.uuidString.lowercased())@example.com",
                    remark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ],
            incomingRequests: [],
            outgoingRequests: [
                CachedContactRequestState(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    requester: AuthUser(id: ownerUserID, email: "owner@example.com"),
                    addressee: AuthUser(
                        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                        email: "peer@example.com"
                    ),
                    status: .pending,
                    message: nil,
                    requesterRemark: nil,
                    addresseeRemark: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_005),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_005),
                    respondedAt: nil
                )
            ],
            resolvedRequests: [],
            lastRefreshAt: Date(timeIntervalSince1970: 1_700_300_100),
            lastSeenIncomingContactRequestAt: Date(timeIntervalSince1970: 1_700_300_090)
        )
    }
}
