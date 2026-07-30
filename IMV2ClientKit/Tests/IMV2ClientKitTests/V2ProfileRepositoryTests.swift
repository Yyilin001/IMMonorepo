import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 profile repository")
struct V2ProfileRepositoryTests {
    @Test("hydration rejects a partial response and purges an unavailable cached profile")
    func handlesCompleteResultsOnly() async throws {
        let userID: UserID = try .init("00000000-0000-0000-0000-000000000a71")
        let otherUserID: UserID = try .init("00000000-0000-0000-0000-000000000a72")
        let key = V2ProfileViewLookupKey(userID: userID, context: .directConversation)
        let store = ProfileProjectionStore()
        let partialReader = ProfileViewReader(results: [.unavailable(key: key)])
        let partialRepository = V2ProfileRepository(store: store, reader: partialReader)
        await #expect(throws: V2ProfileRepositoryError.invalidResponse) {
            _ = try await partialRepository.hydrate([key, .init(userID: otherUserID, context: .directConversation)])
        }

        let existing = try profile(userID: userID, revision: 1)
        await store.seed(existing)
        let repository = V2ProfileRepository(store: store, reader: ProfileViewReader(results: [.unavailable(key: key)]))
        #expect(try await repository.hydrate([key]) == Set([userID]))
        let removed = await store.profile(userID)
        #expect(removed == nil)
    }

    @Test("pending invalidations use a bounded direct context and resolve after persistence")
    func refreshesInvalidations() async throws {
        let userID: UserID = try .init("00000000-0000-0000-0000-000000000a73")
        let view = try profile(userID: userID, revision: 4)
        let store = ProfileProjectionStore(invalidations: [
            .init(userID: userID, minimumRevision: try #require(V2ProfileRevision(rawValue: 4)))
        ])
        let key = V2ProfileViewLookupKey(userID: userID, context: .directConversation)
        let repository = V2ProfileRepository(store: store, reader: ProfileViewReader(results: [.profile(key: key, view: view)]))

        #expect(try await repository.refreshPendingInvalidations() == Set([userID]))
        let persisted = await store.profile(userID)
        #expect(persisted == view)
        let resolved = try await repository.resolve(userID: userID, surface: .directConversation)
        #expect(resolved.displayName == "已读取")
    }

    private func profile(userID: UserID, revision: UInt64) throws -> V2ProfileView {
        try .init(
            userID: userID,
            publicIdentity: .init(userID: userID, handle: .init("profile_user"), displayName: "已读取"),
            avatar: nil,
            state: .active,
            revision: try #require(V2ProfileRevision(rawValue: revision)),
            visibilityRevision: try #require(V2ProfileRevision(rawValue: 1))
        )
    }
}

private actor ProfileProjectionStore: V2ClientProfileProjectionStore {
    private var profiles: [UserID: V2ProfileView] = [:]
    private var invalidations: [V2ProfileInvalidation]

    init(invalidations: [V2ProfileInvalidation] = []) {
        self.invalidations = invalidations
    }

    func profileView(userID: UserID) -> V2ProfileView? { profiles[userID] }
    func profileViews(userIDs: [UserID]) -> [UserID: V2ProfileView] {
        Dictionary(uniqueKeysWithValues: userIDs.compactMap { userID in
            profiles[userID].map { (userID, $0) }
        })
    }
    func saveProfileView(_ profile: V2ProfileView) {
        profiles[profile.userID] = profile
        invalidations.removeAll { $0.userID == profile.userID && $0.minimumRevision <= profile.revision }
    }
    func markProfileUnavailable(userID: UserID) {
        profiles.removeValue(forKey: userID)
        invalidations.removeAll { $0.userID == userID }
    }
    func pendingProfileInvalidations(limit: Int) -> [V2ProfileInvalidation] {
        Array(invalidations.prefix(limit))
    }
    func seed(_ profile: V2ProfileView) { profiles[profile.userID] = profile }
    func profile(_ userID: UserID) -> V2ProfileView? { profiles[userID] }
}

private struct ProfileViewReader: V2ProfileViewReading {
    let results: [V2ProfileViewLookupResult]
    func readProfileViews(_: [V2ProfileViewLookupKey]) async throws -> [V2ProfileViewLookupResult] { results }
}
