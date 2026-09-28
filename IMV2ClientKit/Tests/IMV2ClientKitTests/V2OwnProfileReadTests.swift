import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Own profile allowed local snapshot")
struct V2OwnProfileReadTests {
    private func fixture(revision: UInt64) throws -> (GRDBV2LocalSyncStore, UserID, V2ProfileView) {
        let user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "own-profile-read-\(UUID()).sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        return (store, user, try snapshot(user, revision))
    }
    private func snapshot(_ user: UserID, _ revision: UInt64) throws -> V2ProfileView {
        try .init(userID: user, publicIdentity: .init(userID: user, handle: .init("profile_read"), displayName: "Name", accountKind: .regular),
                  avatar: nil, state: .active, revision: .init(rawValue: revision)!, visibilityRevision: .init(rawValue: revision)!)
    }
    @Test("local confirmed profile returns without starting a network lookup")
    func localFirstNeverWaitsForNetwork() async throws {
        let (store, user, profile) = try fixture(revision: 12)
        try await store.saveOwnProfileSnapshot(profile)
        let reader = OwnReadManager(result: .failure(V2OwnProfileClientError.networkFailure))
        let service = V2ProfileIntentService(store: store, accountID: user, manager: reader)
        #expect(try await service.currentProfile() == profile)
        #expect(await reader.calls() == 0)
        await #expect(throws: V2OwnProfileClientError.networkFailure) { try await service.refreshProfile() }
        #expect(try await service.localProfile() == profile)
        #expect(await reader.calls() == 1)
        try await store.close()
    }
    @Test("late revision 11 cannot replace confirmed revision 12")
    func refreshReturnsNewestConfirmedSnapshot() async throws {
        let (store, user, current) = try fixture(revision: 12)
        try await store.saveOwnProfileSnapshot(current)
        let reader = OwnReadManager(result: .success(try snapshot(user, 11)))
        let service = V2ProfileIntentService(store: store, accountID: user, manager: reader)
        #expect(try await service.refreshProfile() == current)
        #expect(try await service.localProfile() == current)
        try await store.close()
    }
    @Test("no local snapshot and foreign account response remain explicit failures")
    func missingAndForeignAccountDoNotBecomeCachedSuccess() async throws {
        let (store, user, _) = try fixture(revision: 1)
        let unavailable = V2ProfileIntentService(store: store, accountID: user, manager: OwnReadManager(result: .failure(V2OwnProfileClientError.authorizationUnavailable)))
        #expect(try await unavailable.localProfile() == nil)
        await #expect(throws: V2OwnProfileClientError.authorizationUnavailable) { try await unavailable.currentProfile() }
        let foreign = V2ProfileIntentService(store: store, accountID: user, manager: OwnReadManager(result: .success(try snapshot(UserID(uuid: UUID()), 1))))
        await #expect(throws: V2OperationWorkError.accountMismatch) { try await foreign.refreshProfile() }
        #expect(try await foreign.localProfile() == nil)
        try await store.close()
    }
}
private actor OwnReadManager: V2OwnProfileManaging {
    private let result: Result<V2ProfileView, any Error>
    private var count = 0
    init(result: Result<V2ProfileView, any Error>) { self.result = result }
    func calls() -> Int { count }
    func currentProfile() throws -> V2ProfileView { count += 1; return try result.get() }
    func patchProfile(_ command: V2ProfileUpdateCommand) throws -> V2ProfileUpdateResult { throw V2OperationWorkError.invalidTransition }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) throws -> V2ProfileOperationRecoveryResult { throw V2OperationWorkError.invalidTransition }
}
