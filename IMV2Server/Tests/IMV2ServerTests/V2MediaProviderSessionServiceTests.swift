import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 media provider session")
struct V2MediaProviderSessionServiceTests {
    @Test("a claimed opaque download session becomes one bounded provider target")
    func exchangesAndConsumesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(url: try #require(URL(string: "https://media.invalid/object")), headers: ["x-oss-meta-test": "opaque"], expiresAt: now.addingTimeInterval(20))
        let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })

        let result = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)

        #expect(result == target)
        #expect(await store.completedClaims() == [claim])
        #expect(await store.releasedClaims().isEmpty)
    }

    @Test("provider failure releases the fenced session for retry")
    func providerFailureReleasesClaim() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let service = try V2MediaProviderSessionService(store: store, provider: FailingMediaProvider(), now: { now })

        await #expect(throws: ProviderFailure.failed) {
            _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
        }
        #expect(await store.completedClaims().isEmpty)
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("a provider target may not outlive the IM authorization session")
    func rejectsOverlongProviderTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(url: try #require(URL(string: "https://media.invalid/object")), expiresAt: now.addingTimeInterval(31))
        let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })

        await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) {
            _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
        }
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("invalid provider targets are released before object credentials leave the edge")
    func rejectsInsecureProviderTarget() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let store = RecordingDownloadSessionStore(claim: claim)
        let target = V2MediaProviderObjectTarget(url: try #require(URL(string: "http://media.invalid/object")), expiresAt: now.addingTimeInterval(20))
        let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })

        await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) {
            _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
        }
        #expect(await store.releasedClaims() == [claim])
    }

    @Test("provider targets cannot inject ambient authorization headers or URL userinfo")
    func rejectsCredentialInjectionTargets() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let claim = try makeClaim(expiresAt: now.addingTimeInterval(30))
        let targets = [
            V2MediaProviderObjectTarget(
                url: try #require(URL(string: "https://media.invalid/object")),
                headers: ["Authorization": "Bearer provider-secret"],
                expiresAt: now.addingTimeInterval(20)
            ),
            V2MediaProviderObjectTarget(
                url: try #require(URL(string: "https://user:password@media.invalid/object")),
                expiresAt: now.addingTimeInterval(20)
            ),
        ]

        for target in targets {
            let store = RecordingDownloadSessionStore(claim: claim)
            let service = try V2MediaProviderSessionService(store: store, provider: FixedMediaProvider(target: target), now: { now })
            await #expect(throws: V2MediaProviderSessionError.invalidProviderTarget) {
                _ = try await service.exchangeDownload(actorUserID: .init("user"), deviceID: .init("device"), downloadSessionID: claim.downloadSessionID)
            }
            #expect(await store.releasedClaims() == [claim])
        }
    }

    private func makeClaim(expiresAt: Date) throws -> V2ClaimedMediaDownload {
        try .init(mediaID: .init("media"), downloadSessionID: .init("session"), expiresAt: expiresAt, claimToken: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!)
    }
}

private actor RecordingDownloadSessionStore: V2MediaDownloadSessionStore {
    private let claim: V2ClaimedMediaDownload
    private var completed: [V2ClaimedMediaDownload] = []
    private var released: [V2ClaimedMediaDownload] = []

    init(claim: V2ClaimedMediaDownload) { self.claim = claim }

    func claimDownload(requesterUserID _: UserID, deviceID _: DeviceID, downloadSessionID _: MediaDownloadSessionID, now _: Date, leaseDuration _: TimeInterval) -> V2ClaimedMediaDownload { claim }
    func completeDownload(_ claim: V2ClaimedMediaDownload, now _: Date) { completed.append(claim) }
    func releaseDownload(_ claim: V2ClaimedMediaDownload) { released.append(claim) }
    func completedClaims() -> [V2ClaimedMediaDownload] { completed }
    func releasedClaims() -> [V2ClaimedMediaDownload] { released }
}

private struct FixedMediaProvider: V2MediaObjectProvider {
    let target: V2MediaProviderObjectTarget
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) -> V2MediaProviderObjectTarget { target }
}

private struct FailingMediaProvider: V2MediaObjectProvider {
    func issueDownloadTarget(mediaID _: MediaID, expiresAt _: Date) throws -> V2MediaProviderObjectTarget { throw ProviderFailure.failed }
}

private enum ProviderFailure: Error { case failed }
